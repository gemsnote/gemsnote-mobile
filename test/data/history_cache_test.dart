import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  final note = Note.fromJson({'NoteId': 'n', 'Content': 'current', 'Usn': 3});
  final session = StoredSession(account: account, token: 'test-token');
  late AppDatabase db;
  late AuthRepository repo;
  var calls = 0;
  var fail = false;
  var body = 'historic';
  var list = <String>['h1', 'h2'];
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [note],
      tags: [],
      lastSyncUsn: 3,
    );
    calls = 0;
    fail = false;
    body = 'historic';
    list = ['h1', 'h2'];
    final api = Api2Client(
      httpClient: MockClient((request) async {
        calls++;
        if (fail) return http.Response('offline', 503);
        if (request.url.path.endsWith('/getHistories')) {
          return http.Response(
            jsonEncode({
              'Ok': true,
              'Item': [
                for (final id in list)
                  {
                    'HistoryId': id,
                    'UpdatedTime': '2026-01-01',
                    'UpdatedUserId': 'u',
                    'IsMarkdown': true,
                  },
              ],
            }),
            200,
          );
        }
        expect(request.url.path, '/api2/note/getHistoryContent');
        return http.Response(
          jsonEncode({
            'Ok': true,
            'Item': {'HistoryId': 'h1', 'Content': body},
          }),
          200,
        );
      }),
    );
    repo = AuthRepository(api, db, MemorySessions(), SyncCoordinator(api, db));
  });
  tearDown(() => db.raw.close());

  test(
    'complete restore refuses dirty notes before sending mutation',
    () async {
      final api = Api2Client(
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api2/user/getSyncState');
          return http.Response('{"LastSyncUsn":3}', 200);
        }),
      );
      final guarded = AuthRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
      );
      await db.saveLocalNote(account.cacheKey, note);
      await expectLater(
        guarded.restoreHistorySnapshot(session, 'n', 'h1'),
        throwsStateError,
      );
      expect((await db.dirtyNotes(account.cacheKey)).single.content, 'current');
    },
  );

  test(
    'cached history reads and restores without network, including empty body',
    () async {
      await repo.histories(session, 'n');
      body = '';
      await repo.historyContent(session, 'n', 'h1');
      fail = true;
      expect(
        await repo.histories(session, 'n', cachedOnly: true),
        hasLength(2),
      );
      expect(
        await repo.historyContent(session, 'n', 'h1', cachedOnly: true),
        '',
      );
      await repo.restoreHistory(session, 'n', 'h1', cachedOnly: true);
      expect((await db.dirtyNotes(account.cacheKey)).single.content, '');
      final history = (await repo.histories(
        session,
        'n',
        cachedOnly: true,
      )).first;
      await repo.restoreHistory(
        session,
        'n',
        history.id,
        cachedOnly: true,
        isMarkdown: history.isMarkdown,
      );
      expect((await db.dirtyNotes(account.cacheKey)).single.isMarkdown, isTrue);
      expect(await db.lastSyncUsn(account.cacheKey), 3);
      expect(calls, 2);
      await expectLater(
        repo.historyContent(session, 'n', 'h2', cachedOnly: true),
        throwsStateError,
      );
      expect(calls, 2);
    },
  );

  test('online failure is visible, successful refresh prunes only obsolete versions', () async {
    await repo.histories(session, 'n');
    await repo.historyContent(session, 'n', 'h1');
    fail = true;
    await expectLater(repo.histories(session, 'n'), throwsA(isA<Exception>()));
    expect(await repo.histories(session, 'n', cachedOnly: true), hasLength(2));
    fail = false;
    list = ['h1'];
    await repo.histories(session, 'n');
    expect(
      await repo.historyContent(session, 'n', 'h1', cachedOnly: true),
      'historic',
    );
    expect(await repo.histories(session, 'n', cachedOnly: true), hasLength(1));
    list = [];
    await repo.histories(session, 'n');
    await expectLater(
      repo.historyContent(session, 'n', 'h1', cachedOnly: true),
      throwsStateError,
    );
  });

  test('cache is account and note scoped and reset clears it', () async {
    await repo.histories(session, 'n');
    await repo.historyContent(session, 'n', 'h1');
    await expectLater(
      db.cachedHistoryContent('another-account', 'n', 'h1'),
      throwsStateError,
    );
    await expectLater(
      db.cachedHistoryContent(account.cacheKey, 'another-note', 'h1'),
      throwsStateError,
    );
    await db.deactivate(account.cacheKey);
    expect(
      await db.cachedHistoryContent(account.cacheKey, 'n', 'h1'),
      'historic',
    );
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [note],
      tags: [],
      lastSyncUsn: 3,
    );
    expect(await db.cachedHistories(account.cacheKey, 'n'), isEmpty);
  });

  test('tombstoned notes cannot read or repopulate historical cache', () async {
    final histories = await repo.histories(session, 'n');
    await db.saveLocalNote(account.cacheKey, note.copyWith(isTrash: true));
    await db.deleteLocalTrash(account.cacheKey, 'n');
    await expectLater(
      db.cachedHistories(account.cacheKey, 'n'),
      throwsStateError,
    );
    await expectLater(
      db.cacheHistories(account.cacheKey, 'n', histories),
      throwsStateError,
    );
    await expectLater(
      db.cacheHistoryContent(account.cacheKey, 'n', 'h1', 'late response'),
      throwsStateError,
    );
  });

  test(
    'v1 upgrade retains existing notes and enables persistent history cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gemsnote-history-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = '${directory.path}/cache.sqlite';
      // Create a real v1 layout from the current schema without the new table.
      final initial = await AppDatabase.open(databasePath: file);
      await initial.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [note],
        tags: [],
        lastSyncUsn: 3,
      );
      await initial.raw.execute('DROP TABLE note_histories');
      await initial.raw.execute('DROP TABLE account_avatars');
      await initial.raw.execute('DROP TABLE shared_notes');
      await initial.raw.execute('DROP TABLE note_files');
      await initial.raw.setVersion(1);
      await initial.raw.close();
      final upgraded = await AppDatabase.open(databasePath: file);
      try {
        expect(await upgraded.raw.getVersion(), AppDatabase.schemaVersion);
        expect(
          (await upgraded.notes(account.cacheKey)).single.content,
          'current',
        );
        expect(await upgraded.lastSyncUsn(account.cacheKey), 3);
        await upgraded.cacheHistories(
          account.cacheKey,
          'n',
          await repo.histories(session, 'n'),
        );
        await upgraded.cacheHistoryContent(
          account.cacheKey,
          'n',
          'h1',
          'persisted',
        );
      } finally {
        await upgraded.raw.close();
      }
      final reopened = await AppDatabase.open(databasePath: file);
      try {
        expect(
          await reopened.cachedHistoryContent(account.cacheKey, 'n', 'h1'),
          'persisted',
        );
      } finally {
        await reopened.raw.close();
      }
    },
  );
}
