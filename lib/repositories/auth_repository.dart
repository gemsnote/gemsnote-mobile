import '../domain/models/user_group.dart';

import 'dart:async';

import '../data/database/session_transition.dart';
import '../data/database/note_creation_journal.dart';

import 'dart:convert';

import '../core/async/cancellation.dart';

import 'package:crypto/crypto.dart' as crypto;

import '../domain/models/note_bundle.dart';
import '../domain/models/note_creation_review.dart';
import '../domain/models/notebook_conflict.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/api/api2_client.dart';
import '../core/api/api_exception.dart';
import '../data/database/app_database.dart';
import '../data/database/file_download_journal.dart';
import '../data/database/attachment_outbox.dart';
import '../data/database/notebook_creation_journal.dart';
import '../data/database/history_image_cache.dart';
import '../data/database/shared_file_cache.dart';
import '../domain/models/shared_file.dart';
import '../domain/models/body_image_references.dart';
import '../services/account_file_cache.dart';
import '../data/session/session_store.dart';
import '../domain/models/account.dart';
import '../domain/models/default_editor.dart';
import '../domain/models/attachment_upload.dart';
import '../domain/models/note.dart';
import '../domain/models/note_search_result.dart';
import '../domain/models/note_sort.dart';
import '../domain/models/note_file.dart';
import '../domain/models/file_cache_usage.dart';
import '../domain/models/note_image_reference.dart';
import '../domain/models/note_history.dart';
import '../domain/models/notebook.dart';
import '../domain/models/notebook_tree.dart';
import '../domain/models/shared_note.dart';
import '../domain/models/sharing_navigation.dart';
import '../sync/sync_coordinator.dart';
import '../services/note_image_picker.dart';
import '../services/shared_text_inbox.dart';

class StoredSession {
  const StoredSession({required this.account, required this.token});

  final Account account;
  final String token;
}

class PendingLogin {
  const PendingLogin({required this.session, required this.hasCache});

  final StoredSession session;
  final bool hasCache;
}

class AuthRepository {
  AuthRepository(this._api, this._database, this._sessions, this._sync) {
    _sync.resourceConflictBundle = (account, token, local, remote) async {
      final fingerprint = await _database.resourceFingerprint(
        account.cacheKey,
        local.noteId,
      );
      final bundle = await _collectBundle(
        StoredSession(account: account, token: token),
        local,
        expectedRemote: remote,
      );
      return (bundle: bundle, fingerprint: fingerprint);
    };
  }

  final Map<String, Future<void>> _presentationRefreshes = {};
  final Map<String, Future<List<SharedNote>>> _sharedRefreshes = {};
  final Map<String, Future<List<NoteFile>>> _fileRefreshes = {};
  final Map<String, Future<Uint8List>> _inlineDownloads = {};

  Future<void> refreshAccountPresentation(StoredSession session) {
    final key = session.account.cacheKey;
    return _presentationRefreshes[key] ??=
        (() async {
          final profile = await refreshProfile(session);
          await refreshAvatar(session, profile);
        })().whenComplete(() {
          _presentationRefreshes.remove(key);
        });
  }

  final Api2Client _api;
  final AppDatabase _database;
  final SessionStore _sessions;
  Future<Uint8List> downloadInlineImage(
    StoredSession session,
    String noteId,
    Uri uri,
  ) {
    final id = cachedImageFileId(uri, session.account.server);
    if (id == null) return Future.error(StateError('不支持下载此图片地址'));
    final key = '${session.account.cacheKey}:$noteId:$id';
    return _inlineDownloads[key] ??=
        (() async {
          var files = await _database.cachedNoteFiles(
            session.account.cacheKey,
            noteId,
          );
          if (!files.any((file) => file.id == id && !file.isAttachment)) {
            files = await noteFiles(session, noteId);
          }
          for (final file in files) {
            if (file.id == id && !file.isAttachment) {
              return noteImage(session, noteId, file);
            }
          }
          throw StateError('图片不属于当前笔记，请同步后重试');
        })().whenComplete(() {
          _inlineDownloads.remove(key);
        });
  }

  Future<Uint8List?> cachedInlineImage(
    StoredSession session,
    String noteId,
    Uri uri,
  ) async {
    final bound = await _outbox(session).boundImage(noteId, uri);
    if (bound != null) return bound;
    final id = cachedImageFileId(uri, session.account.server);
    if (id == null) return null;
    final files = await _database.cachedNoteFiles(
      session.account.cacheKey,
      noteId,
    );
    for (final file in files) {
      if (file.id == id && !file.isAttachment) {
        try {
          return await _database.cachedNoteImage(
            session.account.cacheKey,
            noteId,
            file,
          );
        } on StateError {
          return await _outbox(session).insertedImage(noteId, id) ??
              await HistoryImageCache(
                _database.raw,
                session.account.cacheKey,
              ).restoredImage(noteId, id);
        }
      }
    }
    return await _outbox(session).insertedImage(noteId, id) ??
        await HistoryImageCache(
          _database.raw,
          session.account.cacheKey,
        ).restoredImage(noteId, id);
  }

  Future<List<NoteFile>> noteFiles(
    StoredSession session,
    String noteId, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedNoteFiles(session.account.cacheKey, noteId);
    }
    final key = '${session.account.cacheKey}:$noteId';
    return _fileRefreshes[key] ??=
        (() async {
          try {
            final files = await _api.noteFiles(
              server: session.account.server,
              token: session.token,
              noteId: noteId,
              userId: session.account.userId,
            );
            await _database.replaceNoteFiles(
              session.account.cacheKey,
              noteId,
              files,
            );
          } on ApiException catch (error) {
            if (error.code == 'notExists' || error.code == 'noPermission') {
              await _database.replaceNoteFiles(
                session.account.cacheKey,
                noteId,
                [],
              );
            }
            rethrow;
          }
          return _database.cachedNoteFiles(session.account.cacheKey, noteId);
        })().whenComplete(() {
          _fileRefreshes.remove(key);
        });
  }

  /// Creates a resource only. The editor must save the returned reference in
  /// its local body; ordinary note sync then establishes server membership.
  Future<String> uploadNoteImage(
    StoredSession session,
    String noteId,
    NoteImageUpload image, {
    Future<void> Function()? beforeSend,
    Future<void> Function(String reference)? confirmed,
    String? uploadId,
  }) async {
    late String reference;
    await _sync.runAttachmentUpload(
      () async {
        final local = (await _database.notes(session.account.cacheKey))
            .where((note) => note.noteId == noteId)
            .firstOrNull;
        if (local == null ||
            local.userId != session.account.userId ||
            local.isTrash ||
            local.isDeleted ||
            local.usn <= 0 ||
            (await _database.pendingNoteIds(session.account.cacheKey))
                .contains(noteId)) {
          throw StateError('请先同步此笔记，再上传图片');
        }
        reference = await _api.uploadNoteImage(
          server: session.account.server,
          token: session.token,
          userId: session.account.userId,
          noteId: noteId,
          image: image,
          beforeSend: beforeSend,
          uploadId: uploadId,
        );
        await confirmed?.call(reference);
      },
      account: session.account,
      token: session.token,
      noteId: noteId,
    );
    return reference;
  }

  /// True means upload and cache refresh succeeded; false means upload was
  /// confirmed but refresh failed. Never repeat the upload to retry refresh.
  Future<bool> uploadAttachment(
    StoredSession session,
    String noteId,
    AttachmentUpload file, {
    Future<void> Function()? beforeSend,
    Future<void> Function(String id)? confirmed,
  }) async {
    var refreshed = false;
    await _sync.runAttachmentUpload(
      () async {
        final local = (await _database.notes(session.account.cacheKey))
            .where((note) => note.noteId == noteId)
            .firstOrNull;
        if (local == null ||
            local.userId != session.account.userId ||
            local.isTrash ||
            local.isDeleted ||
            local.usn <= 0 ||
            (await _database.pendingNoteIds(session.account.cacheKey))
                .contains(noteId)) {
          throw StateError('请先同步此笔记，再上传附件');
        }
        final remoteId = await _api.uploadAttachment(
          server: session.account.server,
          token: session.token,
          userId: session.account.userId,
          noteId: noteId,
          file: file,
          beforeSend: beforeSend,
        );
        await confirmed?.call(remoteId);
        try {
          final pending = _fileRefreshes['${session.account.cacheKey}:$noteId'];
          if (pending != null) await pending;
          final snapshot = await _api.getConflictSnapshot(
            server: session.account.server,
            token: session.token,
            noteId: noteId,
          );
          if (snapshot.note.userId != session.account.userId) {
            throw StateError('accountMismatch');
          }
          if (NoteCreationJournal.matches(local, snapshot.note)) {
            // Attachment membership may advance the USN while the user edits
            // locally. A verified unchanged remote body can become the base
            // without discarding those later edits.
            await _database.markNoteUploaded(
              session.account.cacheKey,
              local,
              snapshot.note,
            );
          } else {
            await _database.mergeChanges(
              account: session.account,
              notebooks: [],
              notes: [snapshot.note],
              tags: [],
              lastSyncUsn: await _database.lastSyncUsn(
                session.account.cacheKey,
              ),
            );
          }
          await noteFiles(session, noteId);
          refreshed = true;
        } on Object {
          // Remote mutation succeeded. Report refresh separately from upload.
        }
      },
      account: session.account,
      token: session.token,
      noteId: noteId,
    );
    return refreshed;
  }

  AttachmentOutbox _outbox(StoredSession session) =>
      AttachmentOutbox(_database.raw, session.account);
  Future<List<PendingAttachment>> pendingAttachments(
    StoredSession session, {
    String? noteId,
  }) => _outbox(session).list(noteId: noteId);
  Future<String> stageAttachment(
    StoredSession session,
    String noteId,
    AttachmentUpload file,
  ) => _outbox(session).stage(noteId, file);
  Future<AttachmentUpload> stagedAttachment(StoredSession session, String id) =>
      _outbox(session).file(id);

  Future<String> stageNoteImage(
    StoredSession session,
    String noteId,
    NoteImageUpload image,
  ) => _outbox(session).stageImage(noteId, image);

  Future<String> stageVisualImage(
    StoredSession session,
    String noteId,
    NoteImageUpload image,
  ) => _database.stageVisualImage(session.account, noteId, image.bytes);

  Future<void> insertStagedImage(StoredSession session, String id) async {
    if (_sync.isBusy) throw StateError('请等待当前同步或上传完成');
    final outbox = _outbox(session);
    final task = (await outbox.list())
        .where((item) => item.id == id)
        .firstOrNull;
    if (task != null && !task.isImage && await outbox.hasBinding(id)) {
      await _sync.runMetadataUpdate(
        () async {
          final local = await _database.searchableNote(
            session.account.cacheKey,
            task.noteId,
          );
          final remote = await _api.getConflictSnapshot(
            server: session.account.server,
            token: session.token,
            noteId: task.noteId,
          );
          if (local == null ||
              local.userId != session.account.userId ||
              remote.note.userId != local.userId ||
              remote.note.usn < local.usn ||
              remote.note.isDeleted ||
              remote.note.isTrash) {
            throw StateError('笔记或资源已变化，请重新打开后重试。');
          }
          if (local.usn != remote.note.usn) {
            if (!NoteCreationJournal.matches(local, remote.note)) {
              throw StateError('请先同步此笔记，再更新附件引用');
            }
            await _database.markNoteUploaded(
              session.account.cacheKey,
              local,
              remote.note,
            );
          }
          await outbox.insertImage(id);
        },
        account: session.account,
        token: session.token,
      );
    } else {
      await outbox.insertImage(id);
    }
  }

  Future<String> uploadStagedImage(StoredSession session, String id) async {
    final outbox = _outbox(session);
    final item = (await outbox.list()).where((e) => e.id == id).firstOrNull;
    if (item == null || !item.isImage || item.state != 'pending') {
      throw StateError('图片不是待上传状态，请先核实已有结果');
    }
    final file = await outbox.file(id);
    final image = await NoteImageUpload.normalize(file.bytes);
    if (await outbox.isLocalPlacement(id)) {
      late String reference;
      await _sync.runAttachmentUpload(
        () async {
          final local = await _database.searchableNote(
            session.account.cacheKey,
            item.noteId,
          );
          if (local == null ||
              local.userId != session.account.userId ||
              local.isTrash ||
              local.isDeleted ||
              local.usn <= 0 ||
              !await _database.hasUnuploadedVisualPlacement(
                session.account.cacheKey,
                item.noteId,
              )) {
            throw StateError('离线图片引用或笔记已变化，请重新打开后核对');
          }
          final remote = await _api.getConflictSnapshot(
            server: session.account.server,
            token: session.token,
            noteId: item.noteId,
          );
          if (remote.note.usn != local.usn ||
              remote.note.userId != local.userId ||
              remote.note.isDeleted ||
              remote.note.isTrash) {
            throw StateError('远端笔记已变化，请先核对冲突后上传图片');
          }
          reference = await _api.uploadNoteImage(
            server: session.account.server,
            token: session.token,
            userId: session.account.userId,
            noteId: item.noteId,
            image: image,
            beforeSend: () => outbox.markSending(id),
            uploadId: session.account.supportsUploadReceipts ? id : null,
          );
          final fileId = cachedImageFileId(
            Uri.parse(reference),
            session.account.server,
          );
          if (fileId == null) throw StateError('图片地址无效');
          await outbox.confirm(id, fileId);
        },
        account: session.account,
        token: session.token,
      );
      await outbox.insertImage(id);
      return reference;
    }
    final reference = await uploadNoteImage(
      session,
      item.noteId,
      image,
      beforeSend: () => outbox.markSending(id),
      confirmed: (reference) async {
        final fileId = cachedImageFileId(
          Uri.parse(reference),
          session.account.server,
        );
        if (fileId == null) throw StateError('图片地址无效');
        await outbox.confirm(id, fileId);
      },
      uploadId: session.account.supportsUploadReceipts ? id : null,
    );
    await insertStagedImage(session, id);
    return reference;
  }

  Future<void> removeStagedAttachment(StoredSession session, String id) async {
    if (_sync.isBusy) throw StateError('请等待当前同步或上传完成');
    await _outbox(session).remove(id);
  }

  Future<void> recoverStagedImageUpload(
    StoredSession session,
    String id,
  ) async {
    if (!session.account.supportsUploadReceipts) {
      throw const ApiException('serverUpgradeRequired');
    }
    await _sync.runMetadataUpdate(
      () async {
        final outbox = _outbox(session);
        final item = (await outbox.list())
            .where((item) => item.id == id)
            .firstOrNull;
        if (item == null || !item.isImage || item.state != 'uncertain') {
          throw StateError('imageTaskChanged');
        }
        final file = await outbox.file(id);
        final image = await NoteImageUpload.normalize(file.bytes);
        final receipt = await _api.imageUploadStatus(
          server: session.account.server,
          token: session.token,
          uploadId: id,
        );
        if (receipt.noteId != item.noteId ||
            receipt.digest != crypto.sha256.convert(image.bytes).toString()) {
          throw StateError('imageReceiptMismatch');
        }
        if (receipt.state != 'pending' && receipt.state != 'retained') {
          throw StateError('uploadAlreadyCleaned');
        }
        await outbox.confirm(id, receipt.fileId);
      },
      account: session.account,
      token: session.token,
    );
  }

  Future<void> cleanupStagedImageUpload(
    StoredSession session,
    String id,
  ) async {
    if (!session.account.supportsUploadReceipts) {
      throw const ApiException('serverUpgradeRequired');
    }
    await _sync.runMetadataUpdate(
      () async {
        final outbox = _outbox(session);
        final item = (await outbox.list())
            .where((item) => item.id == id)
            .firstOrNull;
        if (item == null ||
            !item.isImage ||
            !{'uploaded', 'cleaning'}.contains(item.state) ||
            await outbox.hasBinding(id)) {
          throw StateError('imageTaskChanged');
        }
        final localReferences = await _database.raw.query(
          'notes',
          columns: ['server_id'],
          where: 'account_id = ? AND INSTR(content, ?) > 0',
          whereArgs: [session.account.cacheKey, item.remoteId],
          limit: 1,
        );
        if (localReferences.isNotEmpty) {
          throw StateError('imageAlreadyReferenced');
        }
        final receipt = await _api.imageUploadStatus(
          server: session.account.server,
          token: session.token,
          uploadId: id,
        );
        if (receipt.fileId != item.remoteId || receipt.noteId != item.noteId) {
          throw StateError('imageReceiptMismatch');
        }
        if (!receipt.canCleanup && receipt.state != 'deleted') {
          if (item.state == 'cleaning') await outbox.cancelImageCleanup(id);
          throw const ApiException('imageAlreadyReferenced');
        }
        // Persist before deletion: a lost response must not leave an insert
        // action pointing at an already deleted server resource.
        if (item.state == 'uploaded') await outbox.beginImageCleanup(id);
        try {
          await _api.cleanupImageUpload(
            server: session.account.server,
            token: session.token,
            fileId: receipt.fileId,
          );
        } on ApiException catch (error) {
          if (error.code == 'imageAlreadyReferenced') {
            await outbox.cancelImageCleanup(id);
          }
          rethrow;
        }
        await outbox.markImageCleaned(id);
      },
      account: session.account,
      token: session.token,
    );
  }

  Future<void> retryUncertainAttachment(
    StoredSession session,
    String id,
  ) async {
    if (_sync.isBusy) throw StateError('请等待当前同步或上传完成');
    await _outbox(session).retryUncertain(id);
  }

  Future<bool> uploadStagedAttachment(StoredSession session, String id) async {
    final outbox = _outbox(session);
    final item = (await outbox.list()).where((e) => e.id == id).firstOrNull;
    if (item == null || item.isImage || item.state != 'pending') {
      throw StateError('附件不是待上传状态，请先核实已有结果');
    }
    final file = await outbox.file(id);
    final refreshed = await uploadAttachment(
      session,
      item.noteId,
      file,
      beforeSend: () => outbox.markSending(id),
      confirmed: (remoteId) => outbox.confirm(id, remoteId),
    );
    if (refreshed && await outbox.hasBinding(id)) {
      await insertStagedImage(session, id);
    }
    return refreshed;
  }

  Future<Uint8List> noteImage(
    StoredSession session,
    String noteId,
    NoteFile file, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedNoteImage(session.account.cacheKey, noteId, file);
    }
    try {
      final bytes = await _api.noteImage(
        server: session.account.server,
        token: session.token,
        noteId: noteId,
        userId: session.account.userId,
        file: file,
      );
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      await _database.cacheNoteImage(
        session.account.cacheKey,
        noteId,
        file,
        bytes,
      );
      return bytes;
    } on ApiException catch (error) {
      if ({
        'notExists',
        'noPermission',
        'imageNotInNote',
      }.contains(error.code)) {
        await _database.replaceNoteFiles(session.account.cacheKey, noteId, []);
      }
      rethrow;
    }
  }

  Future<Uint8List> noteAttachment(
    StoredSession session,
    String noteId,
    NoteFile file, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedNoteAttachment(
        session.account.cacheKey,
        noteId,
        file,
      );
    }
    try {
      final bytes = await _api.noteAttachment(
        server: session.account.server,
        token: session.token,
        noteId: noteId,
        userId: session.account.userId,
        file: file,
      );
      await _database.cacheNoteAttachment(
        session.account.cacheKey,
        noteId,
        file,
        bytes,
      );
      return bytes;
    } on ApiException catch (error) {
      if ({
        'notExists',
        'noPermission',
        'attachmentNotInNote',
      }.contains(error.code)) {
        await _database.replaceNoteFiles(session.account.cacheKey, noteId, []);
      }
      rethrow;
    }
  }

  final SyncCoordinator _sync;

  Future<List<SharedNote>> sharedNotes(
    StoredSession session, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedSharedNotes(session.account.cacheKey);
    }
    final key = session.account.cacheKey;
    return _sharedRefreshes[key] ??=
        (() async {
          SharingNavigation? navigation;
          final notes = await _api.sharedNotes(
            onNavigation: (value) => navigation = value,
            server: session.account.server,
            token: session.token,
          );
          await _database.replaceSharedSnapshot(key, notes);
          if (navigation != null) {
            await _database.setAccountMetadata(
              key,
              'sharing',
              navigation!.toJson(),
            );
          }
          return notes;
        })().whenComplete(() {
          _sharedRefreshes.remove(key);
        });
  }

  Future<Note> sharedContent(
    StoredSession session,
    SharedNote note, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedSharedContent(session.account.cacheKey, note);
    }
    try {
      final content = await _api.sharedContent(
        server: session.account.server,
        token: session.token,
        shared: note,
      );
      await _database.cacheSharedContent(
        session.account.cacheKey,
        note,
        content.content,
      );
      return content;
    } on ApiException catch (error) {
      if (error.code == 'noPermission' ||
          error.code == 'notExists' ||
          error.code == 'sharedContentChanged') {
        await _database.removeSharedNote(
          session.account.cacheKey,
          note.note.noteId,
          expected: note,
        );
      }
      rethrow;
    }
  }

  void _requireShareable(StoredSession session, Note note) {
    if (note.isShared ||
        note.userId != session.account.userId ||
        note.usn <= 0 ||
        note.isTrash ||
        note.isDeleted) {
      throw const ApiException('noteNotShareable');
    }
  }

  Future<List<Map<String, Object?>>> shareMembers(
    StoredSession session,
    Note note,
  ) {
    _requireShareable(session, note);
    return _api.shareMembers(
      server: session.account.server,
      token: session.token,
      noteId: note.noteId,
    );
  }

  Future<void> shareNote(StoredSession session, Note note, String email) async {
    _requireShareable(session, note);
    await _api.shareNote(
      server: session.account.server,
      token: session.token,
      noteId: note.noteId,
      email: email.trim(),
    );
  }

  Future<void> revokeNoteShare(
    StoredSession session,
    Note note,
    String userId,
  ) async {
    _requireShareable(session, note);
    await _api.revokeNoteShare(
      server: session.account.server,
      token: session.token,
      noteId: note.noteId,
      userId: userId,
    );
  }

  Future<SharingNavigation> sharingNavigation(
    StoredSession session, {
    bool refresh = false,
  }) async {
    if (refresh) {
      final navigation = await _api.sharingNavigation(
        server: session.account.server,
        token: session.token,
        userId: session.account.userId,
      );
      await _database.setAccountMetadata(
        session.account.cacheKey,
        'sharing',
        navigation.toJson(),
      );
      return navigation;
    }
    return SharingNavigation.fromJson(
      await _database.accountMetadata(session.account.cacheKey, 'sharing'),
    );
  }

  Future<void> moveSharedNote(
    StoredSession session,
    SharedNote shared,
    String notebookId,
  ) async {
    final books = await _database.notebooks(session.account.cacheKey);
    final target = books
        .where((b) => b.notebookId == notebookId && !b.isDeleted)
        .firstOrNull;
    if (target == null || target.usn <= 0) {
      throw const ApiException('notebookNotSynced');
    }
    if (shared.note.userId == session.account.userId) {
      throw const ApiException('noAuth');
    }
    await _api.moveSharedNote(
      server: session.account.server,
      token: session.token,
      noteId: shared.note.noteId,
      notebookId: notebookId,
    );
    final previous = await sharingNavigation(session);
    await _database.setAccountMetadata(
      session.account.cacheKey,
      'sharing',
      SharingNavigation(
        recipients: previous.recipients,
        suggestions: previous.suggestions,
        placements: {...previous.placements, shared.note.noteId: notebookId},
      ).toJson(),
    );
  }

  Future<Map<String, Object?>> queueVerification(
    StoredSession session, {
    bool current = false,
    String email = '',
    String password = '',
    required String language,
  }) async {
    final result = await _api.queueVerification(
      server: session.account.server,
      token: session.token,
      current: current,
      email: email.trim(),
      password: password,
      language: language,
    );
    final profile = await _database.cachedProfile(session.account);
    await _database.setAccountMetadata(session.account.cacheKey, 'profile', {
      'Verified': profile.verified,
      'PendingEmail':
          result['PendingEmail']?.toString() ?? profile.pendingEmail,
    });
    await _database.setAccountMetadata(session.account.cacheKey, 'mail-task', {
      'TaskId': result['TaskId'],
    });
    return result;
  }

  Future<String?> pendingMailTask(StoredSession session) async =>
      (await _database.accountMetadata(
            session.account.cacheKey,
            'mail-task',
          ))['TaskId']
          as String?;
  Future<Map<String, Object?>> emailStatus(
    StoredSession session,
    String taskId,
  ) async {
    Map<String, Object?> result;
    try {
      result = await _api.emailStatus(
        server: session.account.server,
        token: session.token,
        taskId: taskId,
      );
    } on ApiException catch (error) {
      if (error.code != 'mailTaskNotFound') rethrow;
      result = {'State': 'failed', 'Error': error.toString()};
    }
    if (result['State'] == 'sent' || result['State'] == 'failed') {
      await _database.setAccountMetadata(
        session.account.cacheKey,
        'mail-task',
        {},
      );
    }
    return result;
  }

  Future<void> copySharedNote(
    StoredSession session,
    SharedNote shared,
    String notebookId,
  ) async {
    if (shared.note.userId == session.account.userId) {
      throw StateError('sharedCopyOwner');
    }
    final target = (await _database.notebooks(session.account.cacheKey))
        .where((b) => b.notebookId == notebookId && !b.isDeleted)
        .firstOrNull;
    if (target == null || target.usn <= 0) {
      throw const ApiException('notebookNotSynced');
    }
    await _api.copySharedNote(
      server: session.account.server,
      token: session.token,
      shared: shared,
      notebookId: notebookId,
    );
    await synchronize(session);
  }

  Future<Uint8List?> cachedSharedFile(
    StoredSession session,
    SharedNote note,
    SharedFile file,
  ) =>
      SharedFileCache(_database.raw, session.account.cacheKey).read(note, file);

  final _sharedDownloads =
      <(String, String, String, String, String, String), Future<Uint8List>>{};
  Future<Uint8List> downloadSharedFile(
    StoredSession session,
    SharedNote note,
    SharedFile file,
  ) {
    final key = (
      session.account.cacheKey,
      note.note.userId,
      note.note.noteId,
      note.version,
      file.fileId,
      file.version,
    );
    return _sharedDownloads[key] ??=
        (() async {
          final cache = SharedFileCache(
            _database.raw,
            session.account.cacheKey,
          );
          final generation = await cache.begin(note, file);
          try {
            final bytes = await _api.sharedFile(
              server: session.account.server,
              token: session.token,
              shared: note,
              file: file,
            );
            if (!file.isAttachment) {
              final codec = await ui.instantiateImageCodec(
                bytes,
                targetWidth: 256,
              );
              try {
                final frame = await codec.getNextFrame();
                frame.image.dispose();
              } finally {
                codec.dispose();
              }
            }
            await cache.complete(note, file, generation, bytes);
            return bytes;
          } on ApiException catch (error) {
            if ({
              'noPermission',
              'notExists',
              'sharedContentChanged',
            }.contains(error.code)) {
              await _database.removeSharedNote(
                session.account.cacheKey,
                note.note.noteId,
                expected: note,
              );
            } else if ({
              'fileNotFound',
              'sharedFileChanged',
            }.contains(error.code)) {
              await cache.invalidate(file);
            }
            rethrow;
          }
        })().whenComplete(() {
          _sharedDownloads.remove(key);
        });
  }

  Future<String> languagePreference() => _database.languagePreference();
  Future<void> setLanguagePreference(String value) =>
      _database.setLanguagePreference(value);
  Future<bool> appLockEnabled() => _database.appLockEnabled();
  Future<void> setAppLockEnabled(bool value) =>
      _database.setAppLockEnabled(value);

  Future<List<UserGroup>> groups(StoredSession session) =>
      _api.groups(server: session.account.server, token: session.token);
  Future<void> createGroup(StoredSession session, String title) =>
      _api.createGroup(
        server: session.account.server,
        token: session.token,
        title: title.trim(),
      );
  Future<void> renameGroup(
    StoredSession session,
    String groupId,
    String title,
  ) => _api.renameGroup(
    server: session.account.server,
    token: session.token,
    groupId: groupId,
    title: title.trim(),
  );
  Future<void> deleteGroup(StoredSession session, String groupId) =>
      _api.deleteGroup(
        server: session.account.server,
        token: session.token,
        groupId: groupId,
      );
  Future<void> addGroupMember(
    StoredSession session,
    String groupId,
    String identity,
  ) => _api.addGroupMember(
    server: session.account.server,
    token: session.token,
    groupId: groupId,
    identity: identity.trim(),
  );
  Future<void> removeGroupMember(
    StoredSession session,
    String groupId,
    String userId,
  ) => _api.removeGroupMember(
    server: session.account.server,
    token: session.token,
    groupId: groupId,
    userId: userId,
  );

  Future<List<Account>> savedAccounts() async {
    final result = <Account>[];
    for (final account in await _database.cachedAccounts()) {
      final token = await _sessions.read(account.cacheKey);
      if (token != null && token.isNotEmpty) result.add(account);
    }
    return result;
  }

  /// Switching is local: keep dirty rows and credentials for every other account.
  Future<StoredSession> switchAccount(String accountKey) =>
      _sync.changeSession(() => _switchAccount(accountKey));

  Future<StoredSession> _switchAccount(String accountKey) async {
    final accounts = await _database.cachedAccounts();
    final account = accounts.where((a) => a.cacheKey == accountKey).firstOrNull;
    if (account == null) throw StateError('accountCacheMissing');
    final token = await _sessions.read(accountKey);
    if (token == null || token.isEmpty) {
      throw StateError('accountLoginRequired');
    }
    await _database.activateCachedAccount(account);
    return StoredSession(account: account, token: token);
  }

  Future<StoredSession?> restore() async {
    final account = await _database.activeAccount();
    if (account == null) return null;
    final token = await _sessions.read(account.cacheKey);
    if (token == null || token.isEmpty) return null;
    return StoredSession(account: account, token: token);
  }

  Future<PendingLogin> beginLogin({
    required String serverAddress,
    required String identity,
    required String password,
  }) async {
    final server = normalizeServer(serverAddress);
    final result = await _api.login(
      server: server,
      identity: identity.trim(),
      password: password,
    );
    _validateCompatibility(result);
    final cached = await _database.hasAccountCache(result.account.cacheKey);
    return PendingLogin(
      session: StoredSession(account: result.account, token: result.token),
      hasCache: cached,
    );
  }

  Cancellation? _loginCancellation;
  final _syncRequests = <Cancellation>{};

  Future<void> cancelSync() async {
    _loginCancellation?.cancel();
    for (final request in _syncRequests) {
      request.cancel();
    }
    await _sync.cancel();
  }

  Future<StoredSession> completeLogin(
    PendingLogin login, {
    required bool resetCache,
    SyncProgressCallback? onProgress,
  }) async {
    final cancellation = Cancellation();
    if (_loginCancellation != null) throw StateError('sessionChangeInProgress');
    _loginCancellation = cancellation;
    try {
      return await _sync.changeSession(
        () => _completeLogin(
          login,
          resetCache: resetCache,
          onProgress: onProgress,
        ),
      );
    } finally {
      _loginCancellation = null;
    }
  }

  Future<StoredSession> _completeLogin(
    PendingLogin login, {
    required bool resetCache,
    SyncProgressCallback? onProgress,
  }) async {
    final previous = await _database.activeAccount();
    try {
      final session = login.session;
      try {
        _loginCancellation?.check();
        if (login.hasCache && resetCache) {
          await _sync.resetFromServer(
            account: session.account,
            token: session.token,
            onProgress: onProgress,
          );
        } else if (!login.hasCache) {
          await _sync.downloadFreshSnapshot(
            account: session.account,
            token: session.token,
            onProgress: onProgress,
          );
        }
      } on SyncCancelled {
        // Authentication succeeded. Keep the old cache (or an empty account)
        // and let the user resume manually; do not immediately auto-sync again.
        if (!await _database.hasAccountCache(session.account.cacheKey)) {
          await _database.replaceSnapshot(
            account: session.account,
            notebooks: [],
            notes: [],
            tags: [],
            lastSyncUsn: 0,
          );
        }
        await _database.setAutoSync(session.account.cacheKey, false);
      }
      await _sessions.write(session.account.cacheKey, session.token);
      await _database.activateCachedAccount(session.account);
      return session;
    } on Object {
      // A fresh snapshot may have activated the new account before secure
      // storage failed. Keep the visible account and restart behavior consistent.
      if (previous != null) {
        await _database.activateCachedAccount(previous);
      } else {
        await _database.deactivate(login.session.account.cacheKey);
      }
      rethrow;
    }
  }

  Future<void> prepareLogout(
    StoredSession session, {
    SyncProgressCallback? onProgress,
  }) async {
    if (_sync.metadataUpdating) throw StateError('metadataUpdateInProgress');
    if (_sync.attachmentUploading) {
      throw StateError('attachmentUploadInProgress');
    }
    if ((await pendingNoteIds(session.account.cacheKey)).isEmpty &&
        (await _database.dirtyNotebooks(session.account.cacheKey)).isEmpty) {
      return;
    }
    await _sync.uploadPending(
      account: session.account,
      token: session.token,
      onProgress: onProgress,
    );
    if ((await pendingNoteIds(session.account.cacheKey)).isNotEmpty ||
        (await _database.dirtyNotebooks(session.account.cacheKey)).isNotEmpty) {
      throw StateError('请先同步待处理的笔记修改，再删除标签');
    }
  }

  Future<void> logout(
    StoredSession session, {
    bool discardSessionWithPendingChanges = false,
  }) async {
    // Keep the existing protection for independently initiated mutations.
    // Sync jobs are cancellable, but an explicit upload/edit should finish
    // before its UI can log out and discard the active credentials.
    if (_sync.metadataUpdating) throw StateError('metadataUpdateInProgress');
    if (_sync.attachmentUploading) {
      throw StateError('attachmentUploadInProgress');
    }
    await _sync.changeSession(
      () => _logout(
        session,
        discardSessionWithPendingChanges: discardSessionWithPendingChanges,
      ),
    );
  }

  Future<void> _logout(
    StoredSession session, {
    bool discardSessionWithPendingChanges = false,
  }) async {
    if (_sync.metadataUpdating) throw StateError('metadataUpdateInProgress');
    if (_sync.attachmentUploading) {
      throw StateError('attachmentUploadInProgress');
    }
    if (!discardSessionWithPendingChanges &&
        ((await pendingNoteIds(session.account.cacheKey)).isNotEmpty ||
            (await _database.dirtyNotebooks(session.account.cacheKey))
                .isNotEmpty)) {
      throw StateError('请先同步待处理的笔记修改，再删除标签');
    }
    // Local logout retains the account cache and never waits on the network.
    await _sessions.delete(session.account.cacheKey);
    await _database.deactivate(session.account.cacheKey);
  }

  Future<List<Notebook>> notebooks(String accountId) async {
    final books = await _database.notebooks(accountId);
    final placed = await _placedSharedNotes(accountId);
    return books
        .map(
          (b) => Notebook(
            notebookId: b.notebookId,
            parentNotebookId: b.parentNotebookId,
            title: b.title,
            sequence: b.sequence,
            usn: b.usn,
            numberNotes:
                b.numberNotes +
                placed.where((n) => n.notebookId == b.notebookId).length,
            isDeleted: b.isDeleted,
            isDirty: b.isDirty,
          ),
        )
        .toList();
  }

  Future<List<Note>> _placedSharedNotes(String accountId) async {
    final nav = SharingNavigation.fromJson(
      await _database.accountMetadata(accountId, 'sharing'),
    );
    if (nav.placements.isEmpty) return [];
    final books = (await _database.notebooks(accountId))
        .where((b) => !b.isDeleted)
        .map((b) => b.notebookId)
        .toSet();
    final shared = await _database.cachedSharedNotes(accountId);
    return shared
        .where((s) => books.contains(nav.placements[s.note.noteId]))
        .map(
          (s) => s.note.copyWith(
            notebookId: nav.placements[s.note.noteId],
            isShared: true,
          ),
        )
        .toList();
  }

  Future<Account> cachedProfile(StoredSession session) =>
      _database.cachedProfile(session.account);

  Future<Uint8List?> cachedAvatar(StoredSession session) =>
      _database.cachedAvatar(session.account.cacheKey);

  Future<Uint8List?> refreshAvatar(
    StoredSession session,
    Account profile,
  ) async {
    if (profile.cacheKey != session.account.cacheKey) {
      throw const ApiException('accountMismatch');
    }
    final bytes = await _api.downloadAvatar(
      server: profile.server,
      logo: profile.logo,
    );
    if (bytes != null) {
      // Validate before replacing a working cache with a bogus image response.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    }
    await _database.cacheAvatar(session.account.cacheKey, bytes);
    return bytes;
  }

  Future<Account> refreshProfile(StoredSession session) async {
    final profile = await _api.userInfo(
      server: session.account.server,
      token: session.token,
    );
    if (profile.userId != session.account.userId) {
      throw const ApiException('accountMismatch');
    }
    await _database.updateProfile(profile);
    return profile;
  }

  final _historyDownloads =
      <(String, String, String, String, String, bool), Future<Uint8List>>{};

  Future<Uint8List?> cachedHistoryImage(
    StoredSession session,
    String noteId,
    String historyId,
    String content,
    bool isMarkdown,
    Uri uri,
  ) async {
    final id = cachedImageFileId(uri, session.account.server);
    if (id == null ||
        !bodyImageIds(
          content,
          isMarkdown: isMarkdown,
          server: session.account.server,
        ).contains(id)) {
      return null;
    }
    return HistoryImageCache(
      _database.raw,
      session.account.cacheKey,
    ).read(noteId, historyId, id, content);
  }

  Future<Uint8List> downloadHistoryImage(
    StoredSession session,
    String noteId,
    String historyId,
    String content,
    bool isMarkdown,
    Uri uri,
  ) {
    final id = cachedImageFileId(uri, session.account.server);
    if (id == null ||
        !bodyImageIds(
          content,
          isMarkdown: isMarkdown,
          server: session.account.server,
        ).contains(id)) {
      return Future.error(StateError('图片不属于此历史版本'));
    }
    final key = (
      session.account.cacheKey,
      noteId,
      historyId,
      id,
      content,
      isMarkdown,
    );
    return _historyDownloads[key] ??=
        (() async {
          final cache = HistoryImageCache(
            _database.raw,
            session.account.cacheKey,
          );
          final generation = await cache.begin(noteId, historyId, id, content);
          final bytes = await _api.historyImage(
            server: session.account.server,
            token: session.token,
            noteId: noteId,
            historyId: historyId,
            fileId: id,
            expectedContent: content,
            isMarkdown: isMarkdown,
          );
          final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
          try {
            final frame = await codec.getNextFrame();
            frame.image.dispose();
          } finally {
            codec.dispose();
          }
          await cache.complete(
            noteId,
            historyId,
            id,
            content,
            generation,
            bytes,
          );
          return bytes;
        })().whenComplete(() {
          _historyDownloads.remove(key);
        });
  }

  Future<void> restoreHistorySnapshot(
    StoredSession session,
    String noteId,
    String historyId,
  ) async {
    await _sync.runMetadataUpdate(
      () async {
        final items = (await _database.notes(session.account.cacheKey))
            .where((note) => note.noteId == noteId)
            .toList();
        if (items.length != 1 ||
            (await _database.pendingNoteIds(session.account.cacheKey))
                .contains(noteId) ||
            items.single.usn <= 0 ||
            items.single.userId != session.account.userId) {
          throw StateError('请先同步笔记修改，再恢复完整历史版本');
        }
        final pending = await AttachmentOutbox(
          _database.raw,
          session.account,
        ).list(noteId: noteId);
        if (pending.any(
          (item) => item.state != 'uploaded' && item.state != 'inserted',
        )) {
          throw StateError('请先处理待上传附件，再恢复完整历史版本');
        }
        await _api.restoreHistorySnapshot(
          server: session.account.server,
          token: session.token,
          noteId: noteId,
          historyId: historyId,
          usn: items.single.usn,
        );
      },
      account: session.account,
      token: session.token,
    );
    // Pull the authoritative body, format and resource membership; do not
    // manufacture a local file set from an incomplete history manifest.
    await synchronize(session);
  }

  Future<void> restoreHistory(
    StoredSession session,
    String noteId,
    String historyId, {
    bool cachedOnly = false,
    bool? isMarkdown,
  }) async {
    final content = await historyContent(
      session,
      noteId,
      historyId,
      cachedOnly: cachedOnly,
    );
    await _database.restoreHistoryContent(
      session.account.cacheKey,
      noteId,
      content,
      isMarkdown: isMarkdown,
    );
  }

  Future<List<NoteHistory>> histories(
    StoredSession session,
    String noteId, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedHistories(session.account.cacheKey, noteId);
    }
    final items = await _api.getHistories(
      server: session.account.server,
      token: session.token,
      noteId: noteId,
    );
    await _database.cacheHistories(session.account.cacheKey, noteId, items);
    return items;
  }

  Future<String> historyContent(
    StoredSession session,
    String noteId,
    String historyId, {
    bool cachedOnly = false,
  }) async {
    if (cachedOnly) {
      return _database.cachedHistoryContent(
        session.account.cacheKey,
        noteId,
        historyId,
      );
    }
    final content = await _api.getHistoryContent(
      server: session.account.server,
      token: session.token,
      noteId: noteId,
      historyId: historyId,
    );
    await _database.cacheHistoryContent(
      session.account.cacheKey,
      noteId,
      historyId,
      content,
    );
    return content;
  }

  Future<void> updateUsername(
    StoredSession session, {
    required String username,
  }) {
    if (username.trim().isEmpty) {
      throw const FormatException('请填写新用户名');
    }
    return _api.updateUsername(
      server: session.account.server,
      token: session.token,
      username: username.trim(),
    );
  }

  Future<void> requestEmailChange(
    StoredSession session, {
    required String identity,
    required String password,
    required String email,
  }) {
    final trimmed = email.trim();
    if (identity.trim().isEmpty ||
        password.isEmpty ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(trimmed)) {
      throw const FormatException('请填写当前账号、密码及有效的新邮箱');
    }
    // Do not update cached email until the user confirms the emailed link.
    return _api.requestEmailChange(
      server: session.account.server,
      token: session.token,
      userId: session.account.userId,
      identity: identity.trim(),
      password: password,
      email: trimmed,
    );
  }

  Future<void> changePassword(
    StoredSession session, {
    required String identity,
    required String oldPassword,
    required String password,
  }) {
    if (identity.trim().isEmpty || oldPassword.isEmpty || password.isEmpty) {
      throw const FormatException('请填写当前账号、当前密码及新密码');
    }
    return _api.changePassword(
      server: session.account.server,
      token: session.token,
      userId: session.account.userId,
      identity: identity.trim(),
      oldPassword: oldPassword,
      password: password,
    );
  }

  Future<void> uploadAvatar(StoredSession session, {required Uint8List bytes}) {
    return _api.uploadAvatar(
      server: session.account.server,
      token: session.token,
      bytes: bytes,
    );
  }

  Future<List<Notebook>> _notebooksForReview(StoredSession session) async {
    final result = <Notebook>[];
    final ids = <String>{};
    var cursor = 0;
    while (true) {
      final page = await _api.getNotebooks(
        server: session.account.server,
        token: session.token,
        afterUsn: cursor,
      );
      for (final book in page) {
        if (!RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(book.notebookId) ||
            book.usn <= cursor ||
            !ids.add(book.notebookId) ||
            (book.parentNotebookId.isNotEmpty &&
                !RegExp(r'^[0-9a-fA-F]{24}$')
                    .hasMatch(book.parentNotebookId))) {
          throw StateError('notebookConflictInvalidSnapshot');
        }
      }
      result.addAll(page);
      if (page.length < 100) return result;
      final next = page.fold<int>(
        cursor,
        (value, book) => book.usn > value ? book.usn : value,
      );
      if (next <= cursor) throw StateError('notebookSyncCursorStalled');
      cursor = next;
    }
  }

  Future<NoteCreationReview> reviewNoteCreation(
    StoredSession session,
    String id,
  ) async {
    late NoteCreationReview review;
    await _sync.runMetadataUpdate(
      () async {
        final local = (await _database.dirtyNotes(session.account.cacheKey))
            .where((n) => n.noteId == id)
            .firstOrNull;
        if (local == null ||
            local.usn != 0 ||
            local.isDeleted ||
            local.isTrash ||
            local.userId != session.account.userId) {
          throw StateError('noteCreationLocalChanged');
        }
        final snapshot = await _api.getConflictSnapshot(
          server: session.account.server,
          token: session.token,
          noteId: id,
        );
        final remote = snapshot.note;
        if (remote.noteId != id ||
            remote.userId != local.userId ||
            remote.usn <= 0 ||
            remote.isDeleted ||
            remote.isTrash) {
          throw StateError('noteCreationUnavailable');
        }
        review = NoteCreationReview(
          accountId: session.account.cacheKey,
          local: local,
          remote: remote,
        );
      },
      account: session.account,
      token: session.token,
    );
    return review;
  }

  Future<void> recoverNoteCreation(
    StoredSession session,
    NoteCreationReview review,
  ) async {
    if (review.accountId != session.account.cacheKey ||
        review.local.userId != session.account.userId) {
      throw StateError('noteCreationAccount');
    }
    await _sync.runMetadataUpdate(
      () async {
        final fresh = await _api.getConflictSnapshot(
          server: session.account.server,
          token: session.token,
          noteId: review.remote.noteId,
        );
        if (!sameReviewedNote(fresh.note, review.remote)) {
          throw StateError('noteCreationRemoteChanged');
        }
        await _database.recoverNoteCreation(session.account.cacheKey, review);
      },
      account: session.account,
      token: session.token,
    );
  }

  Future<NotebookConflictSnapshot> reviewNotebookConflict(
    StoredSession session,
    String id,
  ) async {
    late NotebookConflictSnapshot snapshot;
    await _sync.runMetadataUpdate(
      () async {
        final local = (await notebooks(session.account.cacheKey))
            .where((n) => n.notebookId == id)
            .firstOrNull;
        if (local == null || local.usn <= 0 || !local.isDirty) {
          throw StateError('notebookConflictLocalChanged');
        }
        final books = await _notebooksForReview(session);
        final remote = books.where((n) => n.notebookId == id).firstOrNull;
        if (remote == null || remote.isDeleted || remote.usn < local.usn) {
          throw StateError('notebookConflictRemoteUnavailable');
        }
        snapshot = NotebookConflictSnapshot(
          accountId: session.account.cacheKey,
          local: local,
          remote: remote,
          remoteBooks: books,
        );
      },
      account: session.account,
      token: session.token,
    );
    return snapshot;
  }

  Future<void> resolveNotebookConflict(
    StoredSession session,
    NotebookConflictSnapshot reviewed, {
    required bool keepLocal,
  }) async {
    if (reviewed.accountId != session.account.cacheKey) {
      throw StateError('notebookConflictAccount');
    }
    await _sync.runMetadataUpdate(
      () async {
        final books = await _notebooksForReview(session);
        final remote = books
            .where((n) => n.notebookId == reviewed.remote.notebookId)
            .firstOrNull;
        if (remote == null || !sameNotebookVersion(remote, reviewed.remote)) {
          throw StateError('notebookConflictRemoteChanged');
        }
        // A newly required parent must still be the one shown during review.
        final reviewedById = {
          for (final book in reviewed.remoteBooks) book.notebookId: book,
        };
        final freshById = {for (final book in books) book.notebookId: book};
        var parent = remote.parentNotebookId;
        final visited = <String>{remote.notebookId};
        if (!keepLocal) {
          while (parent.isNotEmpty) {
            final expected = reviewedById[parent], actual = freshById[parent];
            if (!visited.add(parent) ||
                expected == null ||
                actual == null ||
                actual.isDeleted ||
                !sameNotebookVersion(expected, actual)) {
              throw StateError('notebookConflictRemoteChanged');
            }
            parent = actual.parentNotebookId;
          }
        }
        await _database.resolveNotebookConflict(
          session.account.cacheKey,
          NotebookConflictSnapshot(
            accountId: reviewed.accountId,
            local: reviewed.local,
            remote: remote,
            remoteBooks: books,
          ),
          keepLocal: keepLocal,
        );
      },
      account: session.account,
      token: session.token,
    );
  }

  Future<void> queueNotebookRename(
    StoredSession session,
    String notebookId,
    String title,
  ) => _database.editLocalNotebook(
    session.account.cacheKey,
    notebookId,
    title: title,
  );

  Future<Notebook> createOfflineNotebook(
    StoredSession session,
    String title,
    String parentId,
  ) => NotebookCreationJournal(
    _database.raw,
    session.account.cacheKey,
  ).create(title, parentId);
  Future<String> resolveNotebookId(StoredSession session, String id) =>
      NotebookCreationJournal(
        _database.raw,
        session.account.cacheKey,
      ).resolve(id);
  Future<String?> notebookCreationState(StoredSession session, String id) =>
      NotebookCreationJournal(
        _database.raw,
        session.account.cacheKey,
      ).state(id);

  Future<List<Notebook>> notebookCreationCandidates(
    StoredSession session,
    String id,
  ) async {
    final local = (await notebooks(session.account.cacheKey))
        .firstWhere((book) => book.notebookId == id);
    if (await notebookCreationState(session, id) != 'uncertain') {
      throw StateError('该笔记本没有待核实的创建请求');
    }
    final result = <Notebook>[];
    await _sync.runMetadataUpdate(() async {
      var cursor = 0;
      while (true) {
        final page = await _api.getNotebooks(
          server: session.account.server,
          token: session.token,
          afterUsn: cursor,
        );
        result.addAll(
          page.where(
            (book) =>
                !book.isDeleted &&
                book.title == local.title &&
                book.parentNotebookId == local.parentNotebookId &&
                book.sequence == local.sequence,
          ),
        );
        if (page.length < 100) break;
        final next = page.fold<int>(
          cursor,
          (usn, book) => book.usn > usn ? book.usn : usn,
        );
        if (next <= cursor) throw StateError('notebookSyncCursorStalled');
        cursor = next;
      }
    });
    return result;
  }

  Future<void> confirmNotebookCreation(
    StoredSession session,
    String id,
    Notebook remote,
  ) async {
    if (_sync.isBusy) throw StateError('请等待当前同步完成');
    final local = (await notebooks(session.account.cacheKey))
        .firstWhere((book) => book.notebookId == id);
    await NotebookCreationJournal(
      _database.raw,
      session.account.cacheKey,
    ).confirm(local, remote);
  }

  Future<void> retryNotebookCreation(StoredSession session, String id) async {
    if (_sync.isBusy) throw StateError('请等待当前同步完成');
    await NotebookCreationJournal(
      _database.raw,
      session.account.cacheKey,
    ).retry(id);
  }

  Future<void> queueNotebookMove(
    StoredSession session,
    String notebookId,
    String parentId,
  ) => _database.editLocalNotebook(
    session.account.cacheKey,
    notebookId,
    parentId: parentId,
  );

  Future<void> deleteNotebook(StoredSession session, Notebook notebook) async {
    await _sync.runMetadataUpdate(
      () async {
        final books = await notebooks(session.account.cacheKey);
        final matches = books.where(
          (book) => book.notebookId == notebook.notebookId,
        );
        if (matches.length != 1 ||
            matches.single.isDirty ||
            matches.single.usn <= 0 ||
            matches.single.usn != notebook.usn) {
          throw StateError('笔记本已有变化或待同步修改，请同步后重试');
        }
        if (books.any((book) => book.parentNotebookId == notebook.notebookId)) {
          throw StateError('请先移动或删除子笔记本');
        }
        if ((await notes(
              session.account.cacheKey,
              notebookId: notebook.notebookId,
            )).isNotEmpty ||
            (await _database.dirtyNotes(session.account.cacheKey)).isNotEmpty) {
          throw StateError('请先移走笔记本中的笔记并同步待处理修改');
        }
        await _api.deleteNotebook(
          server: session.account.server,
          token: session.token,
          notebook: matches.single,
        );
      },
      account: session.account,
      token: session.token,
    );
    // Consume the server tombstone through normal sync. A lost response leaves
    // the cache intact and the next sync safely completes the deletion.
    await synchronize(session);
  }

  Future<void> saveNotebook(
    StoredSession session, {
    required String title,
    Notebook? existing,
    String? parentNotebookId,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const FormatException('请输入笔记本名称');
    if (existing != null &&
        (await _database.dirtyNotebooks(session.account.cacheKey))
            .any((n) => n.notebookId == existing.notebookId)) {
      throw StateError('笔记本已有变化或待同步修改，请同步后重试');
    }
    await _sync.runMetadataUpdate(
      () async {
        final notebook = await _api.saveNotebook(
          server: session.account.server,
          token: session.token,
          title: trimmed,
          existing: existing,
          parentNotebookId: parentNotebookId,
        );
        await _database.cacheNotebook(session.account.cacheKey, notebook);
      },
      account: session.account,
      token: session.token,
    );
  }

  Future<void> moveNotebook(
    StoredSession session,
    String notebookId,
    String parentId,
  ) async {
    final current = await notebooks(session.account.cacheKey);
    if (!canMoveNotebook(current, notebookId, parentId)) {
      throw const FormatException('目标笔记本无效，不能移到自身、子级或循环层级下');
    }
    final source = current.firstWhere((n) => n.notebookId == notebookId);
    if (source.parentNotebookId == parentId) return;
    if (source.isDirty) throw StateError('笔记本已有变化或待同步修改，请同步后重试');
    await _sync.runMetadataUpdate(
      () async {
        final moved = await _api.saveNotebook(
          server: session.account.server,
          token: session.token,
          title: source.title,
          existing: source,
          parentNotebookId: parentId,
        );
        if (moved.parentNotebookId != parentId || moved.isDeleted) {
          throw const ApiException('invalidResponse');
        }
        await _database.cacheNotebook(session.account.cacheKey, moved);
      },
      account: session.account,
      token: session.token,
    );
  }

  Future<List<Note>> notes(
    String accountId, {
    String? notebookId,
    bool starredOnly = false,
    bool trashOnly = false,
  }) async {
    final own = await _database.notes(
      accountId,
      notebookId: notebookId,
      starredOnly: starredOnly,
      trashOnly: trashOnly,
    );
    if (starredOnly || trashOnly) return own;
    final ids = own.map((n) => n.noteId).toSet();
    return [
      ...own,
      ...(await _placedSharedNotes(accountId)).where(
        (n) =>
            !ids.contains(n.noteId) &&
            (notebookId == null || n.notebookId == notebookId),
      ),
    ];
  }

  Future<Map<String, int>> tagCounts(String accountId) =>
      _database.tagCounts(accountId);

  Future<Map<String, int>> availableTags(String accountId) =>
      _database.tagCounts(accountId, includeUnused: true);

  Future<void> createTag(StoredSession session, String value) async {
    final name = value.trim();
    _validateTagName(name);
    await _sync.runMetadataUpdate(
      () async {
        final usn = await _api.createTag(
          server: session.account.server,
          token: session.token,
          userId: session.account.userId,
          name: name,
        );
        await _database.cacheTag(session.account.cacheKey, name, usn);
      },
      account: session.account,
      token: session.token,
    );
  }

  static void _validateTagName(String name) {
    if (name.isEmpty ||
        name.runes.length > 200 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('标签名称需为 1–200 个字符，且不能包含换行或控制字符');
    }
  }

  Future<void> deleteTag(StoredSession session, String value) async {
    final name = value.trim();
    _validateTagName(name);
    await _sync.runMetadataUpdate(
      () async {
        if ((await _database.dirtyNotes(session.account.cacheKey)).isNotEmpty) {
          throw StateError('请先同步待处理的笔记修改，再删除标签');
        }
        final usn = await _database.tagUsn(session.account.cacheKey, name);
        await _api.deleteTag(
          server: session.account.server,
          token: session.token,
          name: name,
          usn: usn,
        );
      },
      account: session.account,
      token: session.token,
    );
    await synchronize(session);
  }

  Future<void> renameTag(
    StoredSession session,
    String oldValue,
    String newValue,
  ) async {
    final oldName = oldValue.trim(), newName = newValue.trim();
    _validateTagName(oldName);
    _validateTagName(newName);
    if (oldName == newName) return;
    // API2 has no atomic rename. Upload earlier work and pull all changes before
    // staging the replacements. Failed uploads remain in the normal dirty queue;
    // repeating this operation safely finishes the remaining replacements.
    await synchronize(session);
    late int oldUsn;
    await _sync.runMetadataUpdate(
      () async {
        oldUsn = await _database.tagUsn(session.account.cacheKey, oldName);
        final usn = await _api.createTag(
          server: session.account.server,
          token: session.token,
          userId: session.account.userId,
          name: newName,
        );
        await _database.cacheTag(session.account.cacheKey, newName, usn);
        await _database.replaceTagInNotes(
          session.account.cacheKey,
          oldName,
          newName,
        );
      },
      account: session.account,
      token: session.token,
    );
    await synchronize(session);
    await _sync.runMetadataUpdate(
      () async {
        if ((await _database.dirtyNotes(session.account.cacheKey)).isNotEmpty ||
            await _database.hasTagReferences(
              session.account.cacheKey,
              oldName,
            )) {
          throw StateError('部分笔记仍使用旧标签，请同步后重试重命名');
        }
        await _api.deleteTag(
          server: session.account.server,
          token: session.token,
          name: oldName,
          usn: oldUsn,
        );
      },
      account: session.account,
      token: session.token,
    );
    await synchronize(session);
  }

  Future<List<Note>> notesForTag(String accountId, String tag) =>
      _database.notesForTag(accountId, tag);

  Future<Set<String>> pendingNoteIds(String accountId) =>
      _database.pendingNoteIds(accountId);

  Future<List<Note>> searchNotes(
    String accountId,
    String query, {
    int limit = 50,
  }) => _database.searchNotes(accountId, query, limit: limit);

  Future<List<NoteSearchResult>> searchNoteSummaries(
    String accountId,
    String query, {
    int limit = 50,
  }) => _database.searchNoteSummaries(accountId, query, limit: limit);

  Future<Note?> searchableNote(String accountId, String noteId) =>
      _database.searchableNote(accountId, noteId);

  Future<FileCacheUsage> fileCacheUsage(StoredSession session) =>
      _database.fileCacheUsage(session.account.cacheKey);

  AccountFileCache fileCacheQueue(StoredSession session) => AccountFileCache(
    journal: FileDownloadJournal(_database.raw, session.account.cacheKey),
  );

  Future<DownloadQueueStatus> downloadQueueStatus(StoredSession session) =>
      FileDownloadJournal(_database.raw, session.account.cacheKey).status();

  Future<void> clearFileCache(StoredSession session) =>
      _database.clearFileCache(session.account.cacheKey);

  Future<bool> autoCacheFiles(StoredSession session) =>
      _database.autoCacheFiles(session.account.cacheKey);

  Future<void> setAutoCacheFiles(StoredSession session, bool enabled) =>
      _database.setAutoCacheFiles(session.account.cacheKey, enabled);

  Future<bool> autoSync(StoredSession session) =>
      _database.autoSync(session.account.cacheKey);

  Future<void> setAutoSync(StoredSession session, bool enabled) =>
      _database.setAutoSync(session.account.cacheKey, enabled);

  Future<NoteSort> noteSort(StoredSession session) =>
      _database.noteSort(session.account.cacheKey);

  Future<void> setNoteSort(StoredSession session, NoteSort sort) =>
      _database.setNoteSort(session.account.cacheKey, sort);

  Future<DefaultEditor> defaultEditor(StoredSession session) =>
      _database.defaultEditor(session.account.cacheKey);

  Future<void> setDefaultEditor(StoredSession session, DefaultEditor editor) =>
      _database.setDefaultEditor(session.account.cacheKey, editor);

  Future<Note> createNote(
    StoredSession session, {
    required String notebookId,
    required bool isMarkdown,
    String title = '',
    String content = '',
  }) => _database.createLocalNote(
    account: session.account,
    notebookId: notebookId,
    isMarkdown: isMarkdown,
    title: title,
    content: content,
  );

  Future<Note> importSharedText(
    StoredSession session,
    SharedText source,
    String notebookId, {
    Uint8List? resourceBytes,
  }) async {
    if (source.accountKey.isNotEmpty &&
        source.accountKey != session.account.cacheKey) {
      throw StateError('此分享已指定其他账号');
    }
    AttachmentUpload? resource;
    if (source.hasResource) {
      if (resourceBytes == null ||
          resourceBytes.length != source.resourceSize) {
        throw StateError('分享资源不完整');
      }
      final image = source.resourceKind == 'image'
          ? await NoteImageUpload.normalize(resourceBytes)
          : null;
      resource = AttachmentUpload(
        name: image == null ? source.resourceName : 'image.png',
        bytes: image?.bytes ?? resourceBytes,
      );
    }
    return _database.importSharedText(
      account: session.account,
      shareId: source.id,
      notebookId: notebookId,
      title: source.suggestedTitle,
      content: source.text,
      resource: resource,
      resourceIsImage: source.resourceKind == 'image',
    );
  }

  Future<Note> copyNote(
    StoredSession session,
    Note source,
    String notebookId,
  ) async {
    if (source.userId != session.account.userId) {
      throw StateError('只能复制当前账号的个人笔记');
    }
    late Note copy;
    await _sync.runMetadataUpdate(() async {
      final fingerprint = await _database.resourceFingerprint(
        session.account.cacheKey,
        source.noteId,
      );
      final bundle = await _collectBundle(session, source);
      copy = await _database.copyLocalNote(
        account: session.account,
        source: source,
        notebookId: notebookId,
        filesConfirmedEmpty: bundle.resources.isEmpty,
        bundle: bundle,
        expectedResources: fingerprint,
      );
    });
    return copy;
  }

  Future<NoteBundle> exportBundle(StoredSession session, Note source) async {
    late NoteBundle bundle;
    await _sync.runMetadataUpdate(() async {
      final fingerprint = await _database.resourceFingerprint(
        session.account.cacheKey,
        source.noteId,
      );
      bundle = await _collectBundle(session, source);
      final current = await _database.searchableNote(
        session.account.cacheKey,
        source.noteId,
      );
      if (current == null ||
          !sameReviewedNote(current, source) ||
          fingerprint !=
              await _database.resourceFingerprint(
                session.account.cacheKey,
                source.noteId,
              )) {
        throw StateError('笔记或资源已变化，请重新打开后重试。');
      }
    });
    return bundle;
  }

  Future<Note> importBundle(
    StoredSession session,
    String notebookId,
    NoteBundle bundle,
  ) => _database.importBundle(session.account, notebookId, bundle);

  Future<NoteBundle> _collectBundle(
    StoredSession session,
    Note source, {
    Note? expectedRemote,
  }) async {
    if (source.userId != session.account.userId ||
        source.isDeleted ||
        source.isTrash) {
      throw StateError('笔记或资源已变化，请重新打开后重试。');
    }
    final staged = await _outbox(session).bundledResources(source.noteId);
    final resources = <BundledResource>[];
    final before = source.usn > 0
        ? await _api.getConflictSnapshot(
            server: session.account.server,
            token: session.token,
            noteId: source.noteId,
          )
        : null;
    if (before != null &&
        (expectedRemote == null
            ? before.note.userId != source.userId ||
                  before.note.usn != source.usn
            : !sameReviewedNote(before.note, expectedRemote))) {
      throw StateError('笔记或资源已变化，请重新打开后重试。');
    }
    final cachedFiles = await _database.cachedNoteFiles(
      session.account.cacheKey,
      source.noteId,
    );
    // Gathering a package must not rotate or remove the source's local cache.
    // A server list that dropped a known resource at the same note USN is
    // inconsistent with the snapshot we are packaging.
    final files = source.usn > 0 && expectedRemote?.isDeleted != true
        ? await _api.noteFiles(
            server: session.account.server,
            token: session.token,
            noteId: source.noteId,
            userId: session.account.userId,
          )
        : <NoteFile>[];
    if (expectedRemote == null &&
        cachedFiles.any(
          (known) => !files.any(
            (file) =>
                file.id == known.id && file.isAttachment == known.isAttachment,
          ),
        )) {
      throw StateError('笔记或资源已变化，请重新打开后重试。');
    }
    final selectedFiles = [
      ...files,
      if (expectedRemote != null)
        for (final known in cachedFiles)
          if (!files.any(
            (file) =>
                file.id == known.id && file.isAttachment == known.isAttachment,
          ))
            known,
    ];
    var total = 0;
    for (final file in selectedFiles) {
      Uint8List bytes;
      final original = staged
          .where(
            (r) =>
                r.sourceId == file.id &&
                r.origin == session.account.server.origin &&
                r.isImage != file.isAttachment,
          )
          .firstOrNull;
      if (original != null) {
        bytes = original.file.bytes;
      } else if (cachedFiles.any(
        (known) =>
            known.id == file.id && known.isAttachment == file.isAttachment,
      )) {
        final known = cachedFiles.firstWhere((item) => item.id == file.id);
        try {
          bytes = file.isAttachment
              ? await _database.cachedNoteAttachment(
                  session.account.cacheKey,
                  source.noteId,
                  known,
                )
              : await _database.cachedNoteImage(
                  session.account.cacheKey,
                  source.noteId,
                  known,
                );
        } on StateError {
          if (expectedRemote != null &&
              !files.any(
                (current) =>
                    current.id == file.id &&
                    current.isAttachment == file.isAttachment,
              )) {
            throw StateError('缺少正文中的图片原件，请先下载图片后重试。');
          }
          bytes = file.isAttachment
              ? await _api.noteAttachment(
                  server: session.account.server,
                  token: session.token,
                  noteId: source.noteId,
                  userId: session.account.userId,
                  file: file,
                )
              : await _api.noteImage(
                  server: session.account.server,
                  token: session.token,
                  noteId: source.noteId,
                  userId: session.account.userId,
                  file: file,
                );
        }
      } else {
        bytes = file.isAttachment
            ? await _api.noteAttachment(
                server: session.account.server,
                token: session.token,
                noteId: source.noteId,
                userId: session.account.userId,
                file: file,
              )
            : await _api.noteImage(
                server: session.account.server,
                token: session.token,
                noteId: source.noteId,
                userId: session.account.userId,
                file: file,
              );
      }
      total += bytes.length;
      if (total > 32 * 1024 * 1024 || resources.length >= 64) {
        throw StateError('资源归档超过限制：原文 8 MiB，资源共 32 MiB、最多 64 项。');
      }
      resources.add(
        BundledResource(
          file: AttachmentUpload(
            name: file.title.isEmpty
                ? '${file.id}.${file.isAttachment ? 'bin' : 'png'}'
                : file.title,
            bytes: bytes,
          ),
          isImage: !file.isAttachment,
          sourceId: file.id,
          origin: session.account.server.origin,
        ),
      );
    }
    for (final item in staged) {
      if (item.sourceId.isEmpty ||
          !resources.any(
            (r) => r.sourceId == item.sourceId && r.origin == item.origin,
          )) {
        resources.add(item);
      }
    }
    for (final id in bodyImageIds(
      source.content,
      isMarkdown: source.isMarkdown,
      server: session.account.server,
    )) {
      if (resources.any(
        (r) =>
            r.sourceId == id &&
            r.origin == session.account.server.origin &&
            r.isImage,
      )) {
        continue;
      }
      final bytes = await cachedInlineImage(
        session,
        source.noteId,
        Uri.parse('/api2/file/getImage?fileId=$id'),
      );
      if (bytes == null) throw StateError('缺少正文中的图片原件，请先下载图片后重试。');
      resources.add(
        BundledResource(
          file: AttachmentUpload(name: '$id.png', bytes: bytes),
          isImage: true,
          sourceId: id,
          origin: session.account.server.origin,
        ),
      );
    }
    for (final id in bodyAttachmentIds(
      source.content,
      session.account.server,
    )) {
      if (!resources.any(
        (r) =>
            !r.isImage &&
            r.sourceId == id &&
            r.origin == session.account.server.origin,
      )) {
        throw StateError('缺少正文中的附件原件，请先下载附件后重试。');
      }
    }
    if (before != null) {
      final after = await _api.getConflictSnapshot(
        server: session.account.server,
        token: session.token,
        noteId: source.noteId,
      );
      if (!sameReviewedNote(before.note, after.note)) {
        throw StateError('笔记或资源已变化，请重新打开后重试。');
      }
      final freshFiles = expectedRemote?.isDeleted == true
          ? <NoteFile>[]
          : await noteFiles(session, source.noteId);
      String signature(List<NoteFile> values) {
        final sorted = values.toList()..sort((a, b) => a.id.compareTo(b.id));
        return jsonEncode(
          sorted.map((f) => [f.id, f.isAttachment, f.title, f.type]).toList(),
        );
      }

      if (signature(files) != signature(freshFiles)) {
        throw StateError('笔记或资源已变化，请重新打开后重试。');
      }
    }
    return NoteBundle(source, resources);
  }

  Future<void> saveEditedText(
    StoredSession session,
    String noteId,
    String title,
    String content,
  ) => _database.saveEditedText(
    session.account.cacheKey,
    noteId,
    title,
    content,
  );

  Future<void> deleteTrash(StoredSession session, String noteId) =>
      _database.deleteLocalTrash(session.account.cacheKey, noteId);

  Future<void> saveNoteTags(
    StoredSession session,
    String noteId,
    List<String> tags,
  ) => _database.saveNoteTags(session.account.cacheKey, noteId, tags);

  Future<void> saveNote(StoredSession session, Note note) =>
      _database.saveLocalNote(session.account.cacheKey, note);

  Future<void> _inActiveSession(
    StoredSession session,
    Future<void> Function() action,
  ) async {
    final cancellation = Cancellation();
    _syncRequests.add(cancellation);
    try {
      final epoch =
          SessionTransition.expectedEpoch ??
          await SessionTransition.read(
            _database.raw,
            SessionTransition.epochKey,
          );
      final active = await _database.activeAccount();
      cancellation.check();
      if (active?.cacheKey != session.account.cacheKey) {
        throw const SyncCancelled();
      }
      await runZoned(
        () => cancellation.run(action),
        zoneValues: {SessionTransition.expectedEpochKey: epoch},
      );
      cancellation.check();
    } finally {
      _syncRequests.remove(cancellation);
    }
  }

  Future<void> resetFromServer(
    StoredSession session, {
    SyncProgressCallback? onProgress,
  }) => _inActiveSession(session, () async {
    final profile = await cachedProfile(session);
    Cancellation.current?.check();
    await _sync.resetFromServer(
      account: profile,
      token: session.token,
      onProgress: onProgress,
    );
  });

  Future<void> synchronizeFull(
    StoredSession session, {
    SyncProgressCallback? onProgress,
  }) => _inActiveSession(
    session,
    () => _sync.synchronizeFull(
      account: session.account,
      token: session.token,
      onProgress: onProgress,
    ),
  );

  Future<void> synchronize(
    StoredSession session, {
    SyncProgressCallback? onProgress,
  }) => _inActiveSession(
    session,
    () => _sync.synchronize(
      account: session.account,
      token: session.token,
      onProgress: onProgress,
    ),
  );

  static Uri normalizeServer(String value) {
    final trimmed = value.trim();
    final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('invalidServerAddress');
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  Future<void> requestPasswordReset(String serverAddress, String email) =>
      _api.requestPasswordReset(
        server: normalizeServer(serverAddress),
        email: email.trim(),
      );

  static void _validateCompatibility(LoginResult result) {
    if (_compareVersions(
          Api2Client.clientVersion,
          result.minimumClientVersion,
        ) <
        0) {
      throw const ApiException('clientUpgradeRequired');
    }
    if (_compareVersions(result.serverVersion, Api2Client.clientVersion) < 0) {
      throw const ApiException('serverUpgradeRequired');
    }
  }

  static int _compareVersions(String left, String right) {
    if (right.trim().isEmpty) return 1;
    final a = left.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final b = right.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    for (var index = 0; index < 3; index++) {
      final av = index < a.length ? a[index] : 0;
      final bv = index < b.length ? b[index] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }
}
