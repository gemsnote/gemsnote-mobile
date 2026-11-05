import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/note_creation_journal.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class CreatingApi extends Api2Client {
  @override
  Future<int> getSyncUsn({required Uri server, required String token}) async =>
      100;
  final stored = <String, Note>{};
  final requests = <Note>[];
  final updates = <Note>[];
  bool loseResponse = false, failRead = false;
  Future<void> Function()? duringCreate, duringUpdate;
  @override
  Future<Note> addNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    requests.add(note);
    final saved = stored.putIfAbsent(
      note.noteId,
      () => note.copyWith(usn: 6, isTrash: false),
    );
    await duringCreate?.call();
    if (loseResponse) throw StateError('lost response');
    // Existing server IDs return request metadata and no body.
    return note.copyWith(usn: saved.usn, content: '');
  }

  @override
  Future<({Note note, bool filesConfirmedEmpty})> getConflictSnapshot({
    required Uri server,
    required String token,
    required String noteId,
  }) async {
    if (failRead) throw StateError('read interrupted');
    return (note: stored[noteId]!, filesConfirmedEmpty: true);
  }

  @override
  Future<Note> updateNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    expect(note.usn, stored[note.noteId]!.usn);
    updates.add(note);
    final remote = note.copyWith(usn: note.usn + 1);
    stored[note.noteId] = remote;
    await duringUpdate?.call();
    return remote;
  }
}

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test'),
    username: 'u',
    email: '',
    logo: '',
  );
  late Directory directory;
  late AppDatabase db;
  late CreatingApi api;
  late Note draft;
  Future<void> push() =>
      SyncCoordinator(api, db).uploadPending(account: account, token: 'secret');
  Future<void> reopen() async {
    await db.raw.close();
    db = await AppDatabase.open(databasePath: '${directory.path}/notes.sqlite');
  }

  Future<List<Map<String, Object?>>> attempts() =>
      db.raw.query('note_create_attempts');
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gemsnote-create-note-');
    db = await AppDatabase.open(databasePath: '${directory.path}/notes.sqlite');
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
      title: 'first',
      content: 'first body',
    );
    api = CreatingApi();
  });
  tearDown(() async {
    await db.raw.close();
    await directory.delete(recursive: true);
  });

  test('lost response and restart replay first payload before uploading newer edits', () async {
    api.loseResponse = true;
    await expectLater(push(), throwsStateError);
    await db.saveEditedText(
      account.cacheKey,
      draft.noteId,
      'later',
      'later body',
    );
    await reopen();
    api.loseResponse = false;
    await push();
    expect(api.requests.map((n) => n.content), ['first body', 'first body']);
    expect(api.stored.length, 1);
    expect(api.stored[draft.noteId]!.content, 'later body');
    expect(api.updates.single.usn, 6);
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
    expect(await attempts(), isEmpty);
    expect(await db.lastSyncUsn(account.cacheKey), 5);
  });

  test(
    'failed readback cannot acknowledge creation even with successful add',
    () async {
      api.failRead = true;
      await expectLater(push(), throwsStateError);
      expect(await db.pendingNoteIds(account.cacheKey), {draft.noteId});
      expect(await attempts(), hasLength(1));
      await reopen();
      api.failRead = false;
      await push();
      expect(api.stored.length, 1);
      expect(await attempts(), isEmpty);
    },
  );

  for (final field in ['body', 'owner', 'notebook', 'format', 'tags']) {
    test(
      'existing server ID with different $field is never falsely acknowledged',
      () async {
        api.stored[draft.noteId] = draft.copyWith(
          usn: 6,
          content: field == 'body' ? 'other body' : draft.content,
          userId: field == 'owner' ? 'other' : draft.userId,
          notebookId: field == 'notebook' ? 'other' : draft.notebookId,
          isMarkdown: field != 'format',
          tags: field == 'tags' ? ['other'] : draft.tags,
        );
        await expectLater(push(), throwsStateError);
        expect(
          (await db.dirtyNotes(account.cacheKey)).single.content,
          draft.content,
        );
        expect((await db.dirtyNotes(account.cacheKey)).single.usn, 0);
        expect(await attempts(), hasLength(1));
        expect(api.updates, isEmpty);
      },
    );
  }

  test(
    'new trashed note is created first then trash transition uses known USN',
    () async {
      await db.saveLocalNote(account.cacheKey, draft.copyWith(isTrash: true));
      await push();
      expect(api.requests.single.isTrash, isFalse);
      expect(api.updates.single.isTrash, isTrue);
      expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
    },
  );

  test('edits during create and follow-up update remain recoverable', () async {
    api.duringCreate = () => db.saveEditedText(
      account.cacheKey,
      draft.noteId,
      'second',
      'second body',
    );
    api.duringUpdate = () => db.saveEditedText(
      account.cacheKey,
      draft.noteId,
      'third',
      'third body',
    );
    await push();
    expect(api.stored[draft.noteId]!.content, 'second body');
    final pending = (await db.dirtyNotes(account.cacheKey)).single;
    expect(pending.content, 'third body');
    expect(pending.usn, 7);
    api.duringUpdate = null;
    await push();
    expect(api.stored[draft.noteId]!.content, 'third body');
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
  });

  test(
    'local acknowledgement failure retains journal atomically for retry',
    () async {
      await db.raw.execute(
        "CREATE TRIGGER fail_ack BEFORE DELETE ON note_create_attempts BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );
      await expectLater(push(), throwsA(isA<DatabaseException>()));
      expect((await db.dirtyNotes(account.cacheKey)).single.usn, 0);
      expect(await attempts(), hasLength(1));
      await db.raw.execute('DROP TRIGGER fail_ack');
      await push();
      expect(api.stored.length, 1);
      expect(await attempts(), isEmpty);
    },
  );

  test('v13 upgrade retains draft and creates isolated journal without credentials', () async {
    await db.raw.execute('DROP TABLE note_create_attempts');
    await db.raw.setVersion(13);
    await reopen();
    final journal = NoteCreationJournal(db.raw, account.cacheKey);
    expect((await journal.prepare(draft)).replayed, isFalse);
    expect((await journal.prepare(draft)).replayed, isTrue);
    await expectLater(
      NoteCreationJournal(db.raw, 'other').prepare(draft),
      throwsStateError,
    );
    final payload = (await attempts()).single['payload'] as String;
    expect(payload, isNot(contains('secret')));
    expect(payload, isNot(contains('token')));
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
  });
}
