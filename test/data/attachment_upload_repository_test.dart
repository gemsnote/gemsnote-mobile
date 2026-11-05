import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

const noteId = '507f1f77bcf86cd799439011';
const fileId = '507f1f77bcf86cd799439012';
final original = Note.fromJson({
  'NoteId': noteId,
  'UserId': 'u',
  'Usn': 5,
  'Content': 'body',
});

class UploadApi extends Api2Client {
  @override
  Future<int> getSyncUsn({required Uri server, required String token}) async =>
      100;
  int uploads = 0;
  bool failRefresh = false;
  bool failNoteSave = false;
  Note remote = original;
  final noteWrites = <String>[];
  Future<void> Function()? duringNoteSave;
  Future<void> Function()? duringUpload;
  @override
  Future<Note> addNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    noteWrites.add('add:${note.noteId}');
    if (failNoteSave) throw StateError('conflict');
    await duringNoteSave?.call();
    remote = note.copyWith(usn: 6);
    return remote;
  }

  @override
  Future<Note> updateNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    noteWrites.add('update:${note.noteId}');
    if (failNoteSave) throw StateError('conflict');
    await duringNoteSave?.call();
    remote = note.copyWith(usn: 6);
    return remote;
  }

  @override
  Future<String> uploadAttachment({
    required Uri server,
    required String token,
    required String userId,
    required String noteId,
    required AttachmentUpload file,
    Future<void> Function()? beforeSend,
  }) async {
    await beforeSend?.call();
    uploads++;
    await duringUpload?.call();
    return fileId;
  }

  @override
  Future<({Note note, bool filesConfirmedEmpty})> getConflictSnapshot({
    required Uri server,
    required String token,
    required String noteId,
  }) async {
    if (failRefresh) throw StateError('offline');
    return (
      note: remote.copyWith(usn: remote.usn + 1),
      filesConfirmedEmpty: false,
    );
  }

  @override
  Future<List<NoteFile>> noteFiles({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
  }) async => [
    const NoteFile(id: fileId, title: 'a.txt', type: 'txt', isAttachment: true),
  ];
}

void main() {
  late AppDatabase db;
  late UploadApi api;
  late AuthRepository repo;
  late SyncCoordinator sync;
  late StoredSession session;
  final file = AttachmentUpload(name: 'a.txt', bytes: Uint8List.fromList([1]));
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    session = StoredSession(
      account: Account(
        userId: 'u',
        server: Uri.parse('https://example.com'),
        username: 'user',
        email: '',
        logo: '',
      ),
      token: 't',
    );
    await db.replaceSnapshot(
      account: session.account,
      notebooks: [],
      notes: [original],
      tags: [],
      lastSyncUsn: 5,
    );
    api = UploadApi();
    sync = SyncCoordinator(api, db);
    repo = AuthRepository(api, db, MemorySessions(), sync);
  });
  tearDown(() => db.raw.close());
  Future<bool> upload() => repo.uploadAttachment(session, noteId, file);
  test(
    'upload refreshes note USN and files without skipping sync cursor',
    () async {
      expect(await upload(), isTrue);
      expect((await db.notes(session.account.cacheKey)).single.usn, 6);
      expect(await db.lastSyncUsn(session.account.cacheKey), 5);
      expect(
        (await db.cachedNoteFiles(session.account.cacheKey, noteId)).single.id,
        fileId,
      );
    },
  );

  test('staged attachment is confirmed before failed refresh and never uploaded twice', () async {
    final id = await repo.stageAttachment(session, noteId, file);
    api.failRefresh = true;
    expect(await repo.uploadStagedAttachment(session, id), isFalse);
    final item = (await repo.pendingAttachments(session)).single;
    expect(item.state, 'uploaded');
    expect(item.remoteId, fileId);
    expect((await repo.stagedAttachment(session, id)).bytes, [1]);
    await expectLater(
      repo.uploadStagedAttachment(session, id),
      throwsStateError,
    );
    expect(api.uploads, 1);
  });

  test(
    'lost upload response preserves original and requires explicit retry',
    () async {
      final id = await repo.stageAttachment(session, noteId, file);
      api.duringUpload = () async => throw StateError('timeout');
      await expectLater(
        repo.uploadStagedAttachment(session, id),
        throwsStateError,
      );
      expect(
        (await repo.pendingAttachments(session)).single.state,
        'uncertain',
      );
      await expectLater(
        repo.uploadStagedAttachment(session, id),
        throwsStateError,
      );
      expect(api.uploads, 1);
      await repo.retryUncertainAttachment(session, id);
      api.duringUpload = null;
      expect(await repo.uploadStagedAttachment(session, id), isTrue);
      expect(api.uploads, 2);
      expect((await repo.pendingAttachments(session)).single.state, 'uploaded');
    },
  );

  test(
    'note conflicts before file request leave queued attachment retryable',
    () async {
      final id = await repo.stageAttachment(session, noteId, file);
      await db.saveLocalNote(
        session.account.cacheKey,
        original.copyWith(content: 'draft'),
      );
      api.failNoteSave = true;
      await expectLater(
        repo.uploadStagedAttachment(session, id),
        throwsStateError,
      );
      expect((await repo.pendingAttachments(session)).single.state, 'pending');
      expect(api.uploads, 0);
    },
  );

  test(
    'in-flight queued uploads block task deletion and manual retry',
    () async {
      final id = await repo.stageAttachment(session, noteId, file);
      final started = Completer<void>(), gate = Completer<void>();
      api.duringUpload = () {
        started.complete();
        return gate.future;
      };
      final pending = repo.uploadStagedAttachment(session, id);
      await started.future;
      await expectLater(
        repo.removeStagedAttachment(session, id),
        throwsStateError,
      );
      await expectLater(
        repo.retryUncertainAttachment(session, id),
        throwsStateError,
      );
      gate.complete();
      await pending;
      expect((await repo.pendingAttachments(session)).single.state, 'uploaded');
    },
  );
  test(
    'refresh failure reports confirmed upload separately and does not retry',
    () async {
      api.failRefresh = true;
      expect(await upload(), isFalse);
      expect(api.uploads, 1);
      expect(sync.attachmentUploading, isFalse);
    },
  );
  test(
    'dirty target is uploaded before attachment without uploading other notes',
    () async {
      await db.saveLocalNote(
        session.account.cacheKey,
        original.copyWith(content: 'draft'),
      );
      final other = await db.createLocalNote(
        account: session.account,
        notebookId: '',
        isMarkdown: true,
      );
      expect(await upload(), isTrue);
      expect(api.noteWrites, ['update:$noteId']);
      expect(api.uploads, 1);
      expect(
        (await db.notes(session.account.cacheKey))
            .firstWhere((note) => note.noteId == noteId)
            .content,
        'draft',
      );
      expect(await db.pendingNoteIds(session.account.cacheKey), {other.noteId});
      expect(sync.attachmentUploading, isFalse);
    },
  );
  test('new target uses add and keeps the same ID for attachment', () async {
    final created = await db.createLocalNote(
      account: session.account,
      notebookId: '',
      isMarkdown: true,
      content: 'new',
    );
    expect(await repo.uploadAttachment(session, created.noteId, file), isTrue);
    expect(api.noteWrites, ['add:${created.noteId}']);
    expect(await db.pendingNoteIds(session.account.cacheKey), isEmpty);
  });
  test(
    'conflict stops attachment and leaves the local draft pending',
    () async {
      await db.saveLocalNote(
        session.account.cacheKey,
        original.copyWith(content: 'draft'),
      );
      api.failNoteSave = true;
      await expectLater(upload(), throwsStateError);
      expect(api.uploads, 0);
      expect(await db.pendingNoteIds(session.account.cacheKey), {noteId});
      expect(sync.attachmentUploading, isFalse);
    },
  );
  test(
    'new edits during note upload stop attachment without losing dirty changes',
    () async {
      await db.saveLocalNote(
        session.account.cacheKey,
        original.copyWith(content: 'draft'),
      );
      api.duringNoteSave = () => db.saveLocalNote(
        session.account.cacheKey,
        original.copyWith(content: 'newer'),
      );
      await expectLater(upload(), throwsStateError);
      expect(api.uploads, 0);
      expect(
        (await db.notes(session.account.cacheKey)).single.content,
        'newer',
      );
      expect(await db.pendingNoteIds(session.account.cacheKey), {noteId});
    },
  );
  test('edits during upload retain dirty body and adopt verified attachment version', () async {
    api.duringUpload = () => db.saveLocalNote(
      session.account.cacheKey,
      original.copyWith(content: 'new edit'),
    );
    expect(await upload(), isTrue);
    final after = (await db.notes(session.account.cacheKey)).single;
    expect(after.content, 'new edit');
    expect(after.usn, 6);
    expect(await db.pendingNoteIds(session.account.cacheKey), contains(noteId));
  });
  test('upload excludes sync, reset, duplicate upload and logout', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    api.duringUpload = () {
      started.complete();
      return gate.future;
    };
    final pending = upload();
    await started.future;
    try {
      await expectLater(
        sync.synchronize(account: session.account, token: 't'),
        throwsStateError,
      );
      await expectLater(
        sync.synchronizeFull(account: session.account, token: 't'),
        throwsStateError,
      );
      await expectLater(
        sync.resetFromServer(account: session.account, token: 't'),
        throwsStateError,
      );
      await expectLater(
        sync.downloadFreshSnapshot(account: session.account, token: 't'),
        throwsStateError,
      );
      await expectLater(
        sync.uploadPending(account: session.account, token: 't'),
        throwsStateError,
      );
      await expectLater(upload(), throwsStateError);
      await expectLater(
        repo.logout(session, discardSessionWithPendingChanges: true),
        throwsStateError,
      );
    } finally {
      gate.complete();
    }
    expect(await pending, isTrue);
    expect(api.uploads, 1);
  });
}
