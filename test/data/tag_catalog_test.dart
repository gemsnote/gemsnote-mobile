import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
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
  late AppDatabase db;
  late Account account;
  late StoredSession session;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    account = Account(
      userId: 'u',
      server: Uri.parse('https://example.test/'),
      username: 'user',
      email: '',
      logo: '',
    );
    session = StoredSession(account: account, token: 'token');
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [
        Note.fromJson({
          'NoteId': 'n',
          'UserId': 'u',
          'Usn': 1,
          'Tags': ['local', 'local'],
        }),
        Note.fromJson({
          'NoteId': 'trash',
          'Usn': 2,
          'Tags': ['trash'],
          'IsTrash': true,
        }),
      ],
      tags: [
        {'Tag': 'unused', 'Usn': 1, 'Count': 999},
        {'Tag': 'deleted', 'Usn': 2, 'IsDeleted': true},
      ],
      lastSyncUsn: 2,
    );
  });
  tearDown(() => db.raw.close());

  test('catalog adds unused tags without trusting remote counts or crossing accounts', () async {
    expect(await db.tagCounts(account.cacheKey), {'local': 1});
    expect(await db.tagCounts(account.cacheKey, includeUnused: true), {
      'local': 1,
      'unused': 0,
    });
    expect(await db.tagCounts('other', includeUnused: true), isEmpty);
    await db.cacheTag(account.cacheKey, 'unused', 20);
    await db.cacheTag(account.cacheKey, 'unused', 3);
    final row = await db.raw.query(
      'tags',
      where: 'name = ?',
      whereArgs: ['unused'],
    );
    expect(row.single['usn'], 20);
    expect(await db.lastSyncUsn(account.cacheKey), 2);
  });

  test('create uses API2 form, preserves dirty notes and leaves sync cursor unchanged', () async {
    final current = (await db.notes(account.cacheKey)).single;
    await db.saveLocalNote(
      account.cacheKey,
      current.copyWith(title: 'offline edit'),
    );
    final api = Api2Client(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('getSyncState')) {
          return http.Response('{"LastSyncUsn":100}', 200);
        }
        expect(request.url.path, '/api2/tag/addTag');
        expect(request.headers.values, contains('Bearer token'));
        expect(request.method, 'POST');
        expect(request.bodyFields, {'tag': 'x,y & 中文'});
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode({
            'Tag': 'x,y & 中文',
            'UserId': 'u',
            'Usn': 8,
            'IsDeleted': false,
            'Count': 1,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    await repo.createTag(session, ' x,y & 中文 ');
    await repo.createTag(session, 'x,y & 中文');
    expect((await repo.availableTags(account.cacheKey))['x,y & 中文'], 0);
    expect(await db.lastSyncUsn(account.cacheKey), 2);
    expect(
      (await db.dirtyNotes(account.cacheKey)).single.title,
      'offline edit',
    );
    expect(
      (await db.raw.query(
        'tags',
        where: 'name = ?',
        whereArgs: ['x,y & 中文'],
      )).length,
      1,
    );
  });

  for (final mode in ['user', 'name', 'deleted', 'usn', 'network']) {
    test('invalid create response or failure is not cached: $mode', () async {
      final api = Api2Client(
        httpClient: MockClient((_) async {
          if (mode == 'network') throw http.ClientException('offline');
          return http.Response(
            jsonEncode({
              'Tag': mode == 'name' ? 'wrong' : 'new',
              'UserId': mode == 'user' ? 'other' : 'u',
              'Usn': mode == 'usn' ? 0 : 8,
              'IsDeleted': mode == 'deleted',
            }),
            200,
          );
        }),
      );
      final sync = SyncCoordinator(api, db);
      final repo = AuthRepository(api, db, MemorySessions(), sync);
      await expectLater(
        repo.createTag(session, 'new'),
        throwsA(isA<ApiException>()),
      );
      expect(
        (await repo.availableTags(account.cacheKey)).containsKey('new'),
        isFalse,
      );
      expect(sync.isBusy, isFalse);
      expect(sync.metadataUpdating, isFalse);
      expect(await db.lastSyncUsn(account.cacheKey), 2);
    });
  }

  test('input validation happens before sending any request', () async {
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => throw StateError('unexpected network'),
      ),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    for (final value in ['', ' ', 'x\ntext', 'x\u0000', '😀' * 201]) {
      await expectLater(repo.createTag(session, value), throwsFormatException);
    }
  });

  test(
    'catalog writes exclude sync, snapshot reset, logout and duplicate create',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      var requests = 0;
      final api = Api2Client(
        httpClient: MockClient((request) {
          if (request.url.path.endsWith('getSyncState')) {
            return Future.value(http.Response('{"LastSyncUsn":100}', 200));
          }
          requests++;
          started.complete();
          return response.future;
        }),
      );
      final sync = SyncCoordinator(api, db);
      final repo = AuthRepository(api, db, MemorySessions(), sync);
      final creation = repo.createTag(session, 'new');
      await started.future;
      for (final action in <Future<void> Function()>[
        () => repo.createTag(session, 'another'),
        () => sync.synchronize(account: account, token: 'token'),
        () => sync.synchronizeFull(account: account, token: 'token'),
        () => sync.resetFromServer(account: account, token: 'token'),
        () => sync.uploadPending(account: account, token: 'token'),
        () => sync.runAttachmentUpload(() async {}),
        () => repo.prepareLogout(session),
        () => repo.logout(session, discardSessionWithPendingChanges: true),
      ]) {
        await expectLater(action(), throwsStateError);
      }
      expect(requests, 1);
      response.complete(
        http.Response(
          jsonEncode({
            'Tag': 'new',
            'UserId': 'u',
            'Usn': 8,
            'IsDeleted': false,
          }),
          200,
        ),
      );
      await creation;
      expect(sync.isBusy, isFalse);
      expect(sync.metadataUpdating, isFalse);
    },
  );
}
