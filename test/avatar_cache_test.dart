import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final server = Uri.parse('https://example.test/');
  test('presentation refreshes coalesce and a failed task can retry', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    addTearDown(db.raw.close);
    final account = Account(
      userId: 'u',
      server: server,
      username: 'u',
      email: '',
      logo: '',
    );
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 4,
    );
    var calls = 0;
    var response = Completer<http.Response>();
    final api = Api2Client(
      httpClient: MockClient((request) {
        calls++;
        return response.future;
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    final session = StoredSession(account: account, token: 'test');
    final first = repo.refreshAccountPresentation(session);
    final second = repo.refreshAccountPresentation(session);
    expect(identical(first, second), true);
    final failure = expectLater(first, throwsA(isA<ApiException>()));
    response.complete(http.Response('offline', 503));
    await failure;
    expect(calls, 1);
    response = Completer<http.Response>();
    final retry = repo.refreshAccountPresentation(session);
    response.complete(
      http.Response('{"UserId":"u","Username":"fresh","Logo":""}', 200),
    );
    await retry;
    expect(calls, 2);
    expect((await repo.cachedProfile(session)).username, 'fresh');
    expect(await db.lastSyncUsn(account.cacheKey), 4);
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
  });
  for (final logo in [
    'https://other.test/avatar.png',
    '//other.test/a',
    'file:///tmp/a',
    'https://user:pass@example.test/a',
  ]) {
    test('reject unsafe avatar $logo without request', () async {
      final api = Api2Client(
        httpClient: MockClient(
          (_) async => throw StateError('must not request'),
        ),
      );
      await expectLater(
        api.downloadAvatar(server: server, logo: logo),
        throwsA(isA<ApiException>()),
      );
    });
  }
  test(
    'avatar requests carry no credentials and do not follow redirects',
    () async {
      final api = Api2Client(
        httpClient: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://example.test/files/avatar.png',
          );
          expect(request.followRedirects, false);
          expect(request.headers.containsKey('authorization'), false);
          expect(request.headers.containsKey('cookie'), false);
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      expect(
        await api.downloadAvatar(server: server, logo: '/files/avatar.png'),
        [1, 2, 3],
      );
    },
  );
  for (final mode in ['redirect', 'html', 'empty', 'large']) {
    test('reject invalid avatar $mode', () async {
      final api = Api2Client(
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            mode == 'empty'
                ? []
                : mode == 'large'
                ? Uint8List(2 * 1024 * 1024 + 1)
                : [1],
            mode == 'redirect' ? 302 : 200,
            headers: {
              'content-type': mode == 'html' ? 'text/html' : 'image/png',
            },
          ),
        ),
      );
      await expectLater(
        api.downloadAvatar(server: server, logo: '/files/a'),
        throwsA(isA<ApiException>()),
      );
    });
  }

  test(
    'corrupt image preserves cache; account isolation, logout and clear',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'u',
        server: server,
        username: 'u',
        email: '',
        logo: '/files/a',
      );
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 4,
      );
      final old = Uint8List.fromList([1, 2, 3]);
      await db.cacheAvatar(account.cacheKey, old);
      final api = Api2Client(
        httpClient: MockClient(
          (_) async => http.Response(
            'not an image',
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );
      final repo = AuthRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
      );
      final session = StoredSession(account: account, token: 'test-token');
      await expectLater(
        repo.refreshAvatar(session, account),
        throwsA(anything),
      );
      expect(await repo.cachedAvatar(session), old);
      expect(await db.cachedAvatar('other'), null);
      await db.deactivate(account.cacheKey);
      expect(await repo.cachedAvatar(session), old);
      expect(await db.lastSyncUsn(account.cacheKey), 4);
      await repo.refreshAvatar(
        session,
        Account(
          userId: 'u',
          server: server,
          username: 'u',
          email: '',
          logo: '',
        ),
      );
      expect(await repo.cachedAvatar(session), null);
    },
  );

  test(
    'v2 upgrade preserves notes schema and persists decoded avatar',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp(
        'gemsnote-avatar-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/cache.sqlite';
      final original = await AppDatabase.open(databasePath: path);
      final account = Account(
        userId: 'u',
        server: server,
        username: 'u',
        email: '',
        logo: '/a',
      );
      await original.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 4,
      );
      final draft = await original.createLocalNote(
        account: account,
        notebookId: '',
        isMarkdown: true,
      );
      await original.raw.execute('DROP TABLE account_avatars');
      await original.raw.execute('DROP TABLE shared_notes');
      await original.raw.execute('DROP TABLE note_files');
      await original.raw.setVersion(2);
      await original.raw.close();
      final db = await AppDatabase.open(databasePath: path);
      final png = await File('assets/images/gemsnote_s.png').readAsBytes();
      try {
        final api = Api2Client(
          httpClient: MockClient(
            (_) async => http.Response.bytes(
              png,
              200,
              headers: {'content-type': 'image/png'},
            ),
          ),
        );
        final repo = AuthRepository(
          api,
          db,
          MemorySessions(),
          SyncCoordinator(api, db),
        );
        await repo.refreshAvatar(
          StoredSession(account: account, token: 'test'),
          account,
        );
        expect(
          (await db.dirtyNotes(account.cacheKey)).single.noteId,
          draft.noteId,
        );
        expect(await db.lastSyncUsn(account.cacheKey), 4);
      } finally {
        await db.raw.close();
      }
      final reopened = await AppDatabase.open(databasePath: path);
      try {
        expect(await reopened.cachedAvatar(account.cacheKey), png);
      } finally {
        await reopened.raw.close();
      }
    },
  );
}
