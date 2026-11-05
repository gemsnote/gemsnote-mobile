import 'dart:typed_data';

import 'package:gemsnote/domain/models/attachment_upload.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/note_creation_journal.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;
import 'note_creation_test.dart' show CreatingApi;

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://notes.test'),
    username: 'u',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 't');
  late Directory temp;
  late AppDatabase db;
  late CreatingApi api;
  late SyncCoordinator sync;
  late AuthRepository repo;
  late Note draft;
  Future<Note> local() async => (await db.dirtyNotes(account.cacheKey)).single;
  void connect() {
    sync = SyncCoordinator(api, db);
    repo = AuthRepository(api, db, MemorySessions(), sync);
  }

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    temp = await Directory.systemTemp.createTemp('note-recovery-');
    db = await AppDatabase.open(databasePath: '${temp.path}/db');
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
    draft = await db.createLocalNote(
      account: account,
      notebookId: 'book',
      isMarkdown: true,
      title: 'local title',
      content: 'local body',
    );
    await NoteCreationJournal(db.raw, account.cacheKey).prepare(draft);
    api = CreatingApi();
    api.stored[draft.noteId] = draft.copyWith(
      usn: 8,
      title: 'remote title',
      content: 'remote body',
    );
    connect();
  });
  tearDown(() async {
    await db.raw.close();
    await temp.delete(recursive: true);
  });

  test('review is read-only; recovery survives restart and updates same ID with reviewed USN', () async {
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    expect(review.remote.content, 'remote body');
    expect((await local()).usn, 0);
    expect(await db.raw.query('note_create_attempts'), hasLength(1));
    await repo.recoverNoteCreation(session, review);
    expect(api.requests, isEmpty);
    expect(api.updates, isEmpty);
    expect(await db.raw.query('note_create_attempts'), isEmpty);
    expect(await db.lastSyncUsn(account.cacheKey), 5);
    await db.raw.close();
    db = await AppDatabase.open(databasePath: '${temp.path}/db');
    connect();
    expect((await local()).content, 'local body');
    expect((await local()).usn, 8);
    await sync.uploadPending(account: account, token: 't');
    expect(api.requests, isEmpty);
    expect(api.updates.single.usn, 8);
    expect(api.stored.length, 1);
    expect(api.stored[draft.noteId]!.content, 'local body');
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
  });

  test('local edit after review refuses stale confirmation', () async {
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    await db.saveEditedText(account.cacheKey, draft.noteId, 'new', 'new body');
    await expectLater(
      repo.recoverNoteCreation(session, review),
      throwsStateError,
    );
    expect((await local()).content, 'new body');
    expect((await local()).usn, 0);
    expect(await db.raw.query('note_create_attempts'), hasLength(1));
  });
  test('remote edit at the same USN also requires a new review', () async {
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    api.stored[draft.noteId] = review.remote.copyWith(content: 'changed');
    await expectLater(
      repo.recoverNoteCreation(session, review),
      throwsStateError,
    );
    expect((await local()).usn, 0);
  });
  for (final field in ['owner', 'id', 'deleted', 'trash', 'version']) {
    test('unavailable remote $field cannot be adopted', () async {
      api.stored[draft.noteId] = draft.copyWith(
        usn: field == 'version' ? 0 : 8,
        userId: field == 'owner' ? 'another' : draft.userId,
        noteId: field == 'id' ? 'another' : draft.noteId,
        isDeleted: field == 'deleted',
        isTrash: field == 'trash',
      );
      await expectLater(
        repo.reviewNoteCreation(session, draft.noteId),
        throwsStateError,
      );
      expect((await local()).usn, 0);
    });
  }
  test('account mismatch is rejected before remote access', () async {
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    final other = StoredSession(
      account: Account(
        userId: 'other',
        server: account.server,
        username: '',
        email: '',
        logo: '',
      ),
      token: 'other',
    );
    api.failRead = true;
    await expectLater(
      repo.recoverNoteCreation(other, review),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'error',
          'noteCreationAccount',
        ),
      ),
    );
    expect((await local()).usn, 0);
  });
  test(
    'failed transaction rolls back base USN and request journal together',
    () async {
      final review = await repo.reviewNoteCreation(session, draft.noteId);
      await db.raw.execute(
        "CREATE TRIGGER fail_recover BEFORE DELETE ON note_create_attempts BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );
      await expectLater(
        repo.recoverNoteCreation(session, review),
        throwsA(isA<DatabaseException>()),
      );
      expect((await local()).usn, 0);
      expect(await db.raw.query('note_create_attempts'), hasLength(1));
    },
  );
  test('unsupported clearing tags preserves draft instead of promising an impossible update', () async {
    api.stored[draft.noteId] = api.stored[draft.noteId]!.copyWith(
      tags: ['remote'],
    );
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    await expectLater(
      repo.recoverNoteCreation(session, review),
      throwsA(
        isA<StateError>().having((e) => e.message, 'error', 'noteCreationTags'),
      ),
    );
    expect((await local()).usn, 0);
  });
  test('sync lock rejects recovery without changing local content', () async {
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    final gate = Completer<void>();
    final running = sync.runMetadataUpdate(() => gate.future);
    await expectLater(
      repo.recoverNoteCreation(session, review),
      throwsStateError,
    );
    gate.complete();
    await running;
    expect((await local()).usn, 0);
  });
  test('legacy unsent journal absence can still recover without making another create request', () async {
    await db.raw.delete('note_create_attempts');
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    await repo.recoverNoteCreation(session, review);
    await sync.uploadPending(account: account, token: 't');
    expect(api.requests, isEmpty);
    expect(api.updates, hasLength(1));
  });
  test(
    'pending binary originals and local content survive base adoption',
    () async {
      final bytes = Uint8List.fromList([0, 255, 7, 9]);
      final id = await repo.stageAttachment(
        session,
        draft.noteId,
        AttachmentUpload(name: 'original.bin', bytes: bytes),
      );
      final review = await repo.reviewNoteCreation(session, draft.noteId);
      await repo.recoverNoteCreation(session, review);
      expect((await repo.stagedAttachment(session, id)).bytes, bytes);
      expect(
        (await repo.pendingAttachments(session)).single.noteId,
        draft.noteId,
      );
      expect((await local()).content, draft.content);
    },
  );
  test('server rollback refuses recovery and retains the request', () async {
    final review = await repo.reviewNoteCreation(session, draft.noteId);
    await db.raw.update(
      'accounts',
      {'last_sync_usn': 101},
      where: 'account_id = ?',
      whereArgs: [account.cacheKey],
    );
    await expectLater(
      repo.recoverNoteCreation(session, review),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'error',
          'serverSyncStateReset',
        ),
      ),
    );
    expect((await local()).usn, 0);
    expect(await db.raw.query('note_create_attempts'), hasLength(1));
  });
}
