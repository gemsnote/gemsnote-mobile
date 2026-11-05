import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/large_values.dart';
import 'package:gemsnote/data/database/note_creation_journal.dart';
import 'package:gemsnote/data/session/session_store.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_history.dart';
import 'package:gemsnote/domain/models/shared_note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _NoSessions implements SessionStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String token) async {}
  @override
  Future<void> delete(String key) async {}
}

/// Shared by desktop SQLite tests and native Android CursorWindow tests.
/// Uses only the caller's disposable database and an in-memory API2 fixture.
Future<void> exerciseLargeNoteStorage(AppDatabase db) async {
  final account = Account(
    userId: 'aaaaaaaaaaaaaaaaaaaaaaaa',
    server: Uri.parse('https://fixture.invalid/'),
    username: 'fixture',
    email: '',
    logo: '',
  );
  // A multibyte character crosses a chunk boundary; embedded NUL must survive.
  final body =
      '${'x' * (LargeValueQuery.chunkBytes - 1)}珠玑📝\u0000${'正文😀' * 300000}END';
  expect(utf8.encode(body).length, greaterThan(3 * 1024 * 1024));
  final note = Note(
    noteId: 'bbbbbbbbbbbbbbbbbbbbbbbb',
    notebookId: '',
    userId: account.userId,
    title: 'Large note',
    content: body,
    tags: ['large'],
    usn: 1,
    isMarkdown: true,
    isStarred: true,
    isTrash: false,
    isDeleted: false,
    createdTime: '2026-01-01',
    updatedTime: '2026-01-02',
  );
  await db.replaceSnapshot(
    account: account,
    notebooks: [],
    notes: [note],
    tags: [],
    lastSyncUsn: 1,
  );
  expect((await db.notes(account.cacheKey)).single.content, body);
  expect(
    (await db.notes(account.cacheKey, starredOnly: true)).single.content,
    body,
  );
  expect(
    (await db.notesForTag(account.cacheKey, 'large')).single.content,
    body,
  );
  expect(
    (await db.searchNotes(account.cacheKey, 'Large')).single.content,
    body,
  );
  expect(
    (await db.searchNoteSummaries(account.cacheKey, 'Large')).single.noteId,
    note.noteId,
  );
  expect(
    (await db.searchableNote(account.cacheKey, note.noteId))!.content,
    body,
  );
  final before = await db.noteSnapshotFingerprint(account.cacheKey);
  await db.saveEditedText(account.cacheKey, note.noteId, 'Updated', '$body!');
  expect((await db.dirtyNotes(account.cacheKey)).single.content, '$body!');
  expect(await db.noteSnapshotFingerprint(account.cacheKey), isNot(before));
  await db.saveNoteTags(account.cacheKey, note.noteId, ['large', 'edited']);
  expect((await db.dirtyNotes(account.cacheKey)).single.content, '$body!');

  final created = await db.createLocalNote(
    account: account,
    notebookId: '',
    isMarkdown: true,
    title: 'Offline',
    content: body,
  );
  final journal = NoteCreationJournal(db.raw, account.cacheKey);
  await journal.prepare(created);
  final replay = await journal.prepare(created);
  expect(replay.replayed, true);
  expect(replay.note.content, body);

  const history = NoteHistory(
    id: 'history',
    updatedTime: '2026-01-01',
    updatedUserId: 'aaaaaaaaaaaaaaaaaaaaaaaa',
  );
  await db.cacheHistories(account.cacheKey, note.noteId, [history]);
  await db.cacheHistoryContent(account.cacheKey, note.noteId, history.id, body);
  await db.cacheHistories(account.cacheKey, note.noteId, [history]);
  expect(
    (await db.cachedHistories(account.cacheKey, note.noteId)).single.id,
    history.id,
  );
  expect(
    await db.cachedHistoryContent(account.cacheKey, note.noteId, history.id),
    body,
  );

  final shared = SharedNote(
    note: note.copyWith(userId: 'cccccccccccccccccccccccc'),
    version: 'd' * 64,
  );
  await db.replaceSharedSnapshot(account.cacheKey, [shared]);
  await db.cacheSharedContent(account.cacheKey, shared, body);
  await db.replaceSharedSnapshot(account.cacheKey, [shared]);
  expect(
    (await db.cachedSharedNotes(account.cacheKey)).single.note.noteId,
    note.noteId,
  );
  expect(
    (await db.cachedSharedContent(account.cacheKey, shared)).content,
    body,
  );

  final api = Api2Client(
    httpClient: MockClient((request) async {
      expect(request.url.path, '/api2/bootstrap');
      return http.Response(
        jsonEncode({
          'User': {'UserId': account.userId},
          'Sharing': {
            'Recipients': [
              {
                'UserId': 'cccccccccccccccccccccccc',
                'Username': 'Reader',
                'NoteIds': [note.noteId],
              },
            ],
          },
        }),
        200,
      );
    }),
  );
  final repo = AuthRepository(api, db, _NoSessions(), SyncCoordinator(api, db));
  final session = StoredSession(account: account, token: 'fixture-token');
  // The same ordering as SharedByMePage._load: cache, notes, then remote.
  await repo.sharingNavigation(session);
  expect(await repo.notes(account.cacheKey), hasLength(2));
  final navigation = await repo.sharingNavigation(session, refresh: true);
  expect(navigation.recipientsFor(note.noteId), ['Reader']);
  expect((await repo.sharingNavigation(session)).recipientsFor(note.noteId), [
    'Reader',
  ]);

  // Null/empty/short values and projection/ordering semantics stay unchanged.
  await db.raw.transaction((tx) async {
    await tx.insert('note_histories', {
      'account_id': account.cacheKey,
      'note_id': note.noteId,
      'history_id': 'empty',
      'updated_time': '',
      'updated_user_id': '',
      'content': '',
    });
    await tx.insert('note_histories', {
      'account_id': account.cacheKey,
      'note_id': note.noteId,
      'history_id': 'null',
      'updated_time': '',
      'updated_user_id': '',
      'content': null,
    });
    final rows = await tx.queryLargeValues(
      'note_histories',
      columns: ['history_id', 'content'],
      where: 'history_id != ?',
      whereArgs: ['history'],
      orderBy: 'history_id',
      limit: 2,
    );
    expect(rows, [
      {'history_id': 'empty', 'content': ''},
      {'history_id': 'null', 'content': null},
    ]);
  });
}
