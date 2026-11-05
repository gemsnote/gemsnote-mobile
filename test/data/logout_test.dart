import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/created_note.dart';

import 'cached_login_test.dart' show MemorySessions;

void main() {
  late AppDatabase db;
  late MemorySessions sessions;
  late StoredSession session;
  final requests = <String>[];
  var fail = false;
  late AuthRepository repo;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    sessions = MemorySessions();
    session = StoredSession(
      account: Account(
        userId: 'u',
        server: Uri.parse('https://notes.example.test/'),
        username: 'user',
        email: '',
        logo: '',
      ),
      token: 'test-token',
    );
    await db.replaceSnapshot(
      account: session.account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
    await sessions.write(session.account.cacheKey, session.token);
    requests.clear();
    fail = false;
    Map<String, Object?>? created;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.endsWith('getSyncState')) {
          return http.Response('{"LastSyncUsn":100}', 200);
        }
        if (fail) return http.Response('{"Ok":false,"Msg":"offline"}', 503);
        if (request.method == 'GET') {
          return http.Response(jsonEncode(created), 200);
        }
        expect(request.url.path, '/api2/client/note/add');
        final fields = Uri.splitQueryString(request.body);
        created = createdNote(fields);
        return http.Response(
          jsonEncode({'NoteId': fields['ClientNoteId'], 'Usn': 6}),
          200,
        );
      }),
    );
    repo = AuthRepository(api, db, sessions, SyncCoordinator(api, db));
  });
  tearDown(() => db.raw.close());

  test('clean logout never calls server and clears login state', () async {
    await repo.prepareLogout(session);
    await repo.logout(session);
    expect(requests, isEmpty);
    expect(await repo.restore(), isNull);
    expect(await sessions.read(session.account.cacheKey), isNull);
    expect(await db.hasAccountCache(session.account.cacheKey), isTrue);
  });

  test(
    'dirty logout uploads only, preserving download cursor and cache',
    () async {
      final draft = await db.createLocalNote(
        account: session.account,
        notebookId: 'book',
        isMarkdown: true,
      );
      await repo.prepareLogout(session);
      expect(requests, [
        '/api2/user/getSyncState',
        '/api2/client/note/add',
        '/api2/note/getNote',
        '/api2/note/getNoteContent',
        '/api2/note/getNote',
      ]);
      expect(await db.pendingNoteIds(session.account.cacheKey), isEmpty);
      expect(await db.lastSyncUsn(session.account.cacheKey), 5);
      await repo.logout(session);
      expect(
        (await db.notes(session.account.cacheKey)).single.noteId,
        draft.noteId,
      );
      expect(await repo.restore(), isNull);
    },
  );

  test(
    'upload failure preserves session until explicit force logout',
    () async {
      final draft = await db.createLocalNote(
        account: session.account,
        notebookId: 'book',
        isMarkdown: true,
      );
      fail = true;
      await expectLater(repo.prepareLogout(session), throwsException);
      expect((await repo.restore())?.token, session.token);
      await expectLater(repo.logout(session), throwsStateError);
      expect(await db.pendingNoteIds(session.account.cacheKey), {draft.noteId});
      await repo.logout(session, discardSessionWithPendingChanges: true);
      expect(await repo.restore(), isNull);
      expect(await db.pendingNoteIds(session.account.cacheKey), {draft.noteId});
      expect(requests, ['/api2/user/getSyncState', '/api2/client/note/add']);
      // The same account ID recovers its draft even if its username changes.
      await db.activateCachedAccount(
        Account(
          userId: session.account.userId,
          server: session.account.server,
          username: 'renamed',
          email: '',
          logo: '',
        ),
      );
      await sessions.write(session.account.cacheKey, 'new-token');
      expect((await repo.restore())?.account.username, 'renamed');
      expect(
        (await db.notes(session.account.cacheKey)).single.noteId,
        draft.noteId,
      );
    },
  );
}
