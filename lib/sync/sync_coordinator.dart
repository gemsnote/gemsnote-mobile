import 'dart:async';

import '../core/async/cancellation.dart';
import '../data/database/session_transition.dart';

import '../domain/models/note_bundle.dart';
import '../core/api/api2_client.dart';
import '../core/api/api_exception.dart';
import '../data/database/app_database.dart';
import '../data/database/notebook_creation_journal.dart';
import '../data/database/note_creation_journal.dart';
import '../data/database/sync_run_lease.dart';
import '../domain/models/account.dart';
import '../domain/models/note.dart';
import '../domain/models/body_image_references.dart';
import '../domain/models/notebook.dart';

enum SyncStage { uploading, notebooks, notes, tags, saving }

class SyncProgress {
  const SyncProgress(this.stage, this.completed);

  final SyncStage stage;
  final int completed;
}

typedef SyncProgressCallback = void Function(SyncProgress progress);

class PendingVisualImage implements Exception {
  const PendingVisualImage();

  @override
  String toString() => '笔记含待上传的离线插入图片，请先在附件列表上传图片';
}

class SyncCoordinator {
  SyncCoordinator(this._api, this._database);

  Future<({NoteBundle bundle, String fingerprint})> Function(
    Account account,
    String token,
    Note local,
    Note remote,
  )?
  resourceConflictBundle;

  final Api2Client _api;
  final AppDatabase _database;
  Future<void>? _running;
  Cancellation? _cancellation;
  Future<void> cancel() async {
    _cancellation?.cancel();
    try {
      await _running;
    } on Object {
      /* The owning request reports failure. */
    }
  }

  Future<T> changeSession<T>(Future<T> Function() action) async {
    final gate = SessionTransition(_database.raw);
    final owner = await gate.begin();
    Timer? heartbeat;
    Future<void>? renewal;
    Object? renewalError;
    try {
      await cancel();
      // Workers in other isolates observe the epoch, abort HTTP, then release
      // their SQLite lease. Never delete a live lease to force a switch.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (SessionTransition.alive(
        await SessionTransition.read(_database.raw, 'sync_run_lease'),
      )) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('sessionChangeTimedOut');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      heartbeat = Timer.periodic(const Duration(minutes: 1), (_) {
        renewal = gate.renew(owner).catchError((Object error) {
          renewalError = error;
          _cancellation?.cancel();
        });
      });
      final result = await runZoned(
        action,
        zoneValues: {SessionTransition.zoneKey: owner},
      );
      if (renewalError != null) throw renewalError!;
      return result;
    } finally {
      heartbeat?.cancel();
      try {
        await renewal;
      } finally {
        await gate.release(owner);
      }
    }
  }

  bool _uploadingOnly = false;
  bool _resetting = false;
  bool _fullSync = false;
  bool _attachmentUploading = false;
  bool _metadataUpdating = false;
  bool get isBusy => _running != null;
  bool get attachmentUploading => _attachmentUploading;
  bool get metadataUpdating => _metadataUpdating;

  Future<void> _withRunLease(Future<void> Function() action) async {
    final cancellation = _cancellation = Cancellation();
    final lease = SyncRunLease(_database.raw);
    String? owner;
    Timer? heartbeat;
    Future<void>? checking;
    var lastRenewal = DateTime.now();
    try {
      final epoch =
          SessionTransition.expectedEpoch ??
          await SessionTransition.read(
            _database.raw,
            SessionTransition.epochKey,
          );
      cancellation.check();
      owner = await lease.claim();
      if (owner == null) throw StateError('syncInProgress');
      // The transition may have begun between reading the epoch and claiming.
      if (epoch !=
          await SessionTransition.read(
            _database.raw,
            SessionTransition.epochKey,
          )) {
        cancellation.cancel();
      }
      heartbeat = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (checking != null) return;
        checking = () async {
          try {
            if (epoch !=
                await SessionTransition.read(
                  _database.raw,
                  SessionTransition.epochKey,
                )) {
              cancellation.cancel();
            }
            if (DateTime.now().difference(lastRenewal) >=
                const Duration(minutes: 1)) {
              if (!await lease.renew(owner!)) cancellation.cancel();
              lastRenewal = DateTime.now();
            }
          } on Object {
            cancellation.cancel();
          } finally {
            checking = null;
          }
        }();
      });
      await cancellation.run(() async {
        cancellation.check();
        await action();
        cancellation.check();
      });
    } finally {
      heartbeat?.cancel();
      await checking;
      if (owner != null) await lease.release(owner);
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  /// Keep catalog writes separate from snapshot downloads and cursor changes.
  Future<void> runMetadataUpdate(
    Future<void> Function() action, {
    Account? account,
    String? token,
  }) {
    if (_running != null) return Future.error(StateError('syncInProgress'));
    _metadataUpdating = true;
    return _running =
        _withRunLease(() async {
          if (account != null && token != null) {
            await _guardServerState(account, token);
          }
          await action();
        }).whenComplete(() {
          _running = null;
          _metadataUpdating = false;
        });
  }

  Future<void> runAttachmentUpload(
    Future<void> Function() action, {
    Account? account,
    String? token,
    String? noteId,
  }) {
    if (_running != null) return Future.error(StateError('syncInProgress'));
    _attachmentUploading = true;
    return _running =
        _withRunLease(() async {
          if (account != null && token != null) {
            await _guardServerState(account, token);
          }
          if (account != null && token != null && noteId != null) {
            final target = (await _database.notes(account.cacheKey))
                .where((note) => note.noteId == noteId)
                .firstOrNull;
            if (target != null &&
                !target.isTrash &&
                !target.isDeleted &&
                target.userId == account.userId) {
              await _uploadNotebooks(
                account,
                token,
                onlyNotebookId: target.notebookId,
              );
            }
            // Only acknowledge this note. Do not resolve conflicts into copies or
            // upload unrelated notes as a side effect of attaching one file.
            final dirty = (await _database.dirtyNotes(account.cacheKey))
                .where((note) => note.noteId == noteId)
                .firstOrNull;
            if (dirty != null) {
              if (dirty.isDeleted ||
                  dirty.isTrash ||
                  dirty.userId != account.userId) {
                throw StateError('不能向已删除或回收站笔记上传附件');
              }
              await _uploadNote(account, token, dirty);
              if ((await _database.pendingNoteIds(account.cacheKey))
                  .contains(noteId)) {
                throw StateError('上传正文期间笔记又有修改，请保存后重试');
              }
            }
          }
          await action();
        }).whenComplete(() {
          _running = null;
          _attachmentUploading = false;
        });
  }

  /// Upload dirty notes, then merge all remote rows without clearing local data.
  Future<void> synchronizeFull({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
  }) {
    if (_fullSync) return _running!;
    if (_running != null) return Future.error(StateError('syncInProgress'));
    _fullSync = true;
    return _running =
        _withRunLease(
          () => _synchronize(
            account: account,
            token: token,
            onProgress: onProgress,
            full: true,
          ),
        ).whenComplete(() {
          _running = null;
          _fullSync = false;
        });
  }

  Future<void> synchronize({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
  }) {
    if (_metadataUpdating) {
      return Future.error(StateError('metadataUpdateInProgress'));
    }
    if (_attachmentUploading) {
      return Future.error(StateError('attachmentUploadInProgress'));
    }
    if (_resetting) return Future.error(StateError('resetInProgress'));
    if (_uploadingOnly) {
      return _running!.then(
        (_) =>
            synchronize(account: account, token: token, onProgress: onProgress),
      );
    }
    return _running ??= _withRunLease(
      () =>
          _synchronize(account: account, token: token, onProgress: onProgress),
    ).whenComplete(() => _running = null);
  }

  Future<void> _synchronize({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
    bool full = false,
  }) async {
    final previousUsn = await _database.lastSyncUsn(account.cacheKey);
    final afterUsn = full ? 0 : previousUsn;
    await _uploadChanges(account, token, onProgress);
    // Fix the checkpoint before reading separate resource streams. A change
    // arriving later must remain eligible for the next incremental download.
    final checkpoint = await _api.getSyncUsn(
      server: account.server,
      token: token,
    );
    if (checkpoint < previousUsn) throw StateError('serverSyncStateReset');
    final notebooks = await _allNotebooks(
      account,
      token,
      onProgress,
      afterUsn: afterUsn,
    );
    final notes = await _allNotes(
      account,
      token,
      onProgress,
      afterUsn: afterUsn,
    );
    final tags = await _allTags(account, token, onProgress, afterUsn: afterUsn);
    onProgress?.call(SyncProgress(SyncStage.saving, notes.length));
    Cancellation.current?.check();
    await _database.mergeChanges(
      account: account,
      notebooks: notebooks,
      notes: notes,
      tags: tags,
      lastSyncUsn: checkpoint,
    );
  }

  Future<void> uploadPending({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
  }) {
    if (_metadataUpdating) {
      return Future.error(StateError('metadataUpdateInProgress'));
    }
    if (_attachmentUploading) {
      return Future.error(StateError('attachmentUploadInProgress'));
    }
    if (_resetting) return Future.error(StateError('resetInProgress'));
    if (_running != null) return _running!;
    _uploadingOnly = true;
    return _running =
        _withRunLease(() => _uploadChanges(account, token, onProgress))
            .whenComplete(() {
              _running = null;
              _uploadingOnly = false;
            });
  }

  Future<void> _uploadNotebooks(
    Account account,
    String token, {
    String? onlyNotebookId,
  }) async {
    final allBooks = await _database.notebooks(account.cacheKey);
    final pendingBooks = allBooks.where((book) => book.isDirty).toList();
    final byId = {for (final book in allBooks) book.notebookId: book};
    final dirtyById = {for (final book in pendingBooks) book.notebookId: book};
    final notebooks = <Notebook>[];
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) throw StateError('notebookParentCycle');
      final book = byId[id];
      if (book == null) throw StateError('notebookParentMissing');
      if (book.parentNotebookId.isNotEmpty) visit(book.parentNotebookId);
      visiting.remove(id);
      visited.add(id);
      if (dirtyById[id] != null) notebooks.add(dirtyById[id]!);
    }

    // Upload final parents first, including through unchanged ancestors. This
    // avoids transient cycles when reversing an existing parent/child relation.
    if (onlyNotebookId != null && byId.containsKey(onlyNotebookId)) {
      visit(onlyNotebookId);
    } else if (onlyNotebookId == null) {
      for (final book in pendingBooks) {
        visit(book.notebookId);
      }
    }
    final creations = NotebookCreationJournal(_database.raw, account.cacheKey);
    for (final queued in notebooks) {
      final local = (await _database.notebooks(account.cacheKey))
          .firstWhere((book) => book.notebookId == queued.notebookId);
      if (local.usn == 0) {
        final request = await creations.begin(
          local.notebookId,
          idempotent: account.supportsUploadReceipts,
        );
        final remote = await _api.saveNotebook(
          server: account.server,
          token: token,
          title: request.title,
          parentNotebookId: request.parentNotebookId,
          clientNotebookId: account.supportsUploadReceipts
              ? request.notebookId
              : null,
        );
        await creations.confirm(request, remote);
        continue;
      }
      Notebook remote;
      try {
        remote = await _api.saveNotebook(
          server: account.server,
          token: token,
          title: local.title,
          existing: local,
          parentNotebookId: local.parentNotebookId,
        );
      } on ApiException catch (error) {
        if (error.code != 'conflict' || error.statusCode != null) rethrow;
        // A previous upload may have committed before its response was lost.
        // Only acknowledge an exact desired result; never overwrite a conflict.
        final changed = await _allNotebooks(
          account,
          token,
          null,
          afterUsn: local.usn,
        );
        final found = changed
            .where((n) => n.notebookId == local.notebookId)
            .firstOrNull;
        if (found == null ||
            found.isDeleted ||
            found.title != local.title ||
            found.parentNotebookId != local.parentNotebookId ||
            found.sequence != local.sequence) {
          throw StateError('笔记本存在远端冲突，本地修改已保留；请在笔记本菜单中选择“核对远端修改”');
        }
        remote = found;
      }
      await _database.markNotebookUploaded(account.cacheKey, local, remote);
    }
    if (onlyNotebookId == null &&
        (await _database.dirtyNotebooks(account.cacheKey)).isNotEmpty) {
      throw StateError('localChangesDuringSync');
    }
  }

  Future<void> _uploadNote(Account account, String token, Note local) async {
    final pendingVisual = await _database.hasUnuploadedVisualPlacement(
      account.cacheKey,
      local.noteId,
    );
    if (pendingVisual && local.usn > 0) {
      throw const PendingVisualImage();
    }
    if (local.usn > 0) {
      final remote = await _api.updateNote(
        server: account.server,
        token: token,
        note: local,
      );
      await _database.markNoteUploaded(account.cacheKey, local, remote);
      return;
    }
    var initial = local;
    if (pendingVisual) {
      final sourceIds = (await _database.pendingVisualSourceIds(
        account.cacheKey,
        local.noteId,
      )).where(local.content.contains).toSet();
      if (sourceIds.isEmpty) throw StateError('新笔记图片引用已变化，请重试同步');
      initial = local.copyWith(
        content: bodyWithoutPendingVisualImages(
          local.content,
          account.server,
          sourceIds,
        ),
      );
    }
    final attempt = await NoteCreationJournal(
      _database.raw,
      account.cacheKey,
    ).prepare(initial);
    var remote = await _api.addNote(
      server: account.server,
      token: token,
      note: attempt.note,
    );
    if (remote.noteId != local.noteId || remote.usn <= 0) {
      throw StateError('invalidUploadResponse');
    }
    // The add response echoes request fields and omits Content even for replay.
    // Verify the stored body at a stable USN before acknowledging any creation,
    // including pending notes originating from versions without this journal.
    final snapshot = await _api.getConflictSnapshot(
      server: account.server,
      token: token,
      noteId: local.noteId,
    );
    if (!NoteCreationJournal.matches(attempt.note, snapshot.note)) {
      throw StateError('新笔记创建结果与原请求不一致，本地修改已保留；请在笔记菜单选择“核对新建结果”');
    }
    remote = snapshot.note;
    await _database.markNoteUploaded(account.cacheKey, attempt.note, remote);
    final pending = (await _database.dirtyNotes(account.cacheKey))
        .where((note) => note.noteId == local.noteId)
        .firstOrNull;
    if (pending != null && !pending.isDeleted) {
      // Preserve later edits across an idempotent replay. Now that the base USN
      // is known, upload them with ordinary optimistic concurrency checks.
      await _uploadNotebooks(
        account,
        token,
        onlyNotebookId: pending.notebookId,
      );
      final latest = (await _database.dirtyNotes(account.cacheKey))
          .where((note) => note.noteId == local.noteId)
          .firstOrNull;
      if (latest == null || latest.isDeleted) return;
      if (await _database.hasUnuploadedVisualPlacement(
        account.cacheKey,
        local.noteId,
      )) {
        throw const PendingVisualImage();
      }
      final updated = await _api.updateNote(
        server: account.server,
        token: token,
        note: latest,
      );
      await _database.markNoteUploaded(account.cacheKey, latest, updated);
    }
  }

  Future<void> _uploadChanges(
    Account account,
    String token,
    SyncProgressCallback? onProgress,
  ) async {
    if ((await _database.dirtyNotebooks(account.cacheKey)).isNotEmpty ||
        (await _database.pendingNoteIds(account.cacheKey)).isNotEmpty) {
      await _guardServerState(account, token);
    }
    await _uploadNotebooks(account, token);
    final dirty = await _database.dirtyNotes(account.cacheKey);
    var deferredVisualImage = false;
    onProgress?.call(SyncProgress(SyncStage.uploading, 0));
    for (var index = 0; index < dirty.length; index++) {
      final local = dirty[index];
      if (local.isDeleted) {
        try {
          await _api.deleteTrash(
            server: account.server,
            token: token,
            note: local,
          );
          await _database.acknowledgeDeletion(account.cacheKey, local);
        } on ApiException catch (error) {
          if (error.code != 'conflict' ||
              error.statusCode != null ||
              local.usn <= 0) {
            rethrow;
          }
          final remote = await _api.getConflictSnapshot(
            server: account.server,
            token: token,
            noteId: local.noteId,
          );
          if (remote.note.isDeleted) {
            await _database.acknowledgeDeletion(account.cacheKey, local);
          } else {
            await _database.restoreConflictedDeletion(
              account.cacheKey,
              local,
              remote.note,
            );
            throw StateError('远端笔记已修改，已取消本机永久删除。请检查最新内容后再决定是否删除。');
          }
        }
        onProgress?.call(SyncProgress(SyncStage.uploading, index + 1));
        continue;
      }
      try {
        await _uploadNote(account, token, local);
      } on PendingVisualImage {
        // Keep this note local until its original image is uploaded, but let
        // independent notes finish uploading in this pass.
        deferredVisualImage = true;
        onProgress?.call(SyncProgress(SyncStage.uploading, index + 1));
        continue;
      } on ApiException catch (error) {
        if (error.code != 'conflict' ||
            error.statusCode != null ||
            local.usn <= 0) {
          rethrow;
        }
        final remote = await _api.getConflictSnapshot(
          server: account.server,
          token: token,
          noteId: local.noteId,
        );
        final package =
            (remote.note.isDeleted ||
                    remote.note.content != local.content ||
                    remote.note.isMarkdown != local.isMarkdown) &&
                resourceConflictBundle != null
            ? await resourceConflictBundle!(account, token, local, remote.note)
            : null;
        final copy = await _database.resolveNoteConflict(
          account.cacheKey,
          local,
          remote.note,
          filesConfirmedEmpty: remote.filesConfirmedEmpty,
          bundle: package?.bundle,
          account: package == null ? null : account,
          expectedResources: package?.fingerprint,
        );
        if (copy != null) {
          // Persist the copy first. Failed/lost uploads leave this same ID dirty
          // for the next attempt, rather than creating another conflict copy.
          await _uploadNote(account, token, copy);
        }
      }
      onProgress?.call(SyncProgress(SyncStage.uploading, index + 1));
    }
    if (deferredVisualImage) {
      throw const PendingVisualImage();
    }
  }

  Future<void> _guardServerState(Account account, String token) async {
    final known = await _database.knownSyncUsn(account.cacheKey);
    final remote = await _api.getSyncUsn(server: account.server, token: token);
    if (remote < known) throw StateError('serverSyncStateReset');
  }

  /// Destructive replacement is invoked only after explicit user confirmation.
  Future<void> resetFromServer({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
  }) {
    if (_running != null) return Future.error(StateError('syncInProgress'));
    _resetting = true;
    return _running =
        _withRunLease(() async {
          final expected = await _database.noteSnapshotFingerprint(
            account.cacheKey,
          );
          await _downloadSnapshot(
            account: account,
            token: token,
            onProgress: onProgress,
            expectedNoteSnapshot: expected,
          );
        }).whenComplete(() {
          _running = null;
          _resetting = false;
        });
  }

  Future<void> downloadFreshSnapshot({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
  }) {
    if (_running != null) return Future.error(StateError('syncInProgress'));
    return _running = _withRunLease(
      () => _downloadSnapshot(
        account: account,
        token: token,
        onProgress: onProgress,
      ),
    ).whenComplete(() => _running = null);
  }

  Future<void> _downloadSnapshot({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
    String? expectedNoteSnapshot,
  }) async {
    final checkpoint = await _api.getSyncUsn(
      server: account.server,
      token: token,
    );
    final notebooks = await _allNotebooks(
      account,
      token,
      onProgress,
      afterUsn: 0,
    );
    final notes = await _allNotes(account, token, onProgress, afterUsn: 0);
    final tags = await _allTags(account, token, onProgress, afterUsn: 0);
    onProgress?.call(SyncProgress(SyncStage.saving, notes.length));
    Cancellation.current?.check();
    await _database.replaceSnapshot(
      account: account,
      notebooks: notebooks,
      notes: notes,
      tags: tags,
      lastSyncUsn: checkpoint,
      expectedNoteSnapshot: expectedNoteSnapshot,
    );
  }

  Future<List<Notebook>> _allNotebooks(
    Account account,
    String token,
    SyncProgressCallback? progress, {
    required int afterUsn,
  }) async {
    final result = <Notebook>[];
    progress?.call(SyncProgress(SyncStage.notebooks, 0));
    var cursor = afterUsn;
    while (true) {
      final page = await _api.getNotebooks(
        server: account.server,
        token: token,
        afterUsn: cursor,
      );
      result.addAll(page);
      progress?.call(SyncProgress(SyncStage.notebooks, result.length));
      if (page.isEmpty || page.length < 100) break;
      final next = page.fold<int>(
        cursor,
        (usn, item) => item.usn > usn ? item.usn : usn,
      );
      if (next <= cursor) throw StateError('notebookSyncCursorStalled');
      cursor = next;
    }
    return result;
  }

  Future<List<Note>> _allNotes(
    Account account,
    String token,
    SyncProgressCallback? progress, {
    required int afterUsn,
  }) async {
    final result = <Note>[];
    progress?.call(SyncProgress(SyncStage.notes, 0));
    var cursor = afterUsn;
    while (true) {
      final page = await _api.getNotesWithContent(
        server: account.server,
        token: token,
        afterUsn: cursor,
      );
      result.addAll(page);
      progress?.call(SyncProgress(SyncStage.notes, result.length));
      if (page.isEmpty || page.length < Api2Client.syncNotePageSize) break;
      final next = page.fold<int>(
        cursor,
        (usn, item) => item.usn > usn ? item.usn : usn,
      );
      if (next <= cursor) throw StateError('noteSyncCursorStalled');
      cursor = next;
    }
    return result;
  }

  Future<List<Map<String, Object?>>> _allTags(
    Account account,
    String token,
    SyncProgressCallback? progress, {
    required int afterUsn,
  }) async {
    final result = <Map<String, Object?>>[];
    progress?.call(SyncProgress(SyncStage.tags, 0));
    var cursor = afterUsn;
    while (true) {
      final page = await _api.getTags(
        server: account.server,
        token: token,
        afterUsn: cursor,
      );
      result.addAll(page);
      progress?.call(SyncProgress(SyncStage.tags, result.length));
      if (page.isEmpty || page.length < 100) break;
      final next = page.fold<int>(cursor, (usn, item) {
        final value = _integer(item['Usn']);
        return value > usn ? value : usn;
      });
      if (next <= cursor) throw StateError('tagSyncCursorStalled');
      cursor = next;
    }
    return result;
  }

  static int _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}
