import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/async/cancellation.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/session_transition.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  late AppDatabase db;
  final a = Account(
    userId: 'same',
    server: Uri.parse('https://old.test/'),
    username: 'one',
    email: '',
    logo: '',
  );
  final b = Account(
    userId: 'same',
    server: Uri.parse('https://new.test/'),
    username: 'two',
    email: '',
    logo: '',
  );
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    for (final account in [a, b]) {
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [
          Note.fromJson({'NoteId': 'old', 'Content': 'kept', 'Usn': 1}),
        ],
        tags: [],
        lastSyncUsn: 1,
      );
    }
    await db.activateCachedAccount(a);
  });
  tearDown(() => db.raw.close());

  for (final mode in ['reset', 'full', 'incremental']) {
    test(
      '$mode cancels a blocked request, retains cache and releases lease',
      () async {
        final started = Completer<void>();
        final response = Completer<http.Response>();
        var calls = 0;
        final api = Api2Client(
          httpClient: MockClient((_) {
            calls++;
            started.complete();
            return response.future;
          }),
        );
        final sync = SyncCoordinator(api, db);
        final task = switch (mode) {
          'reset' => sync.resetFromServer(account: a, token: 'old-token'),
          'full' => sync.synchronizeFull(account: a, token: 'old-token'),
          _ => sync.synchronize(account: a, token: 'old-token'),
        };
        final assertion = expectLater(task, throwsA(isA<SyncCancelled>()));
        await started.future;
        await sync.cancel().timeout(const Duration(seconds: 2));
        await assertion;
        expect(sync.isBusy, false);
        expect(await SessionTransition.read(db.raw, 'sync_run_lease'), '');
        response.complete(http.Response('{"LastSyncUsn":2}', 200));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls, 1);
        expect((await db.notes(a.cacheKey)).single.content, 'kept');
        expect(await db.lastSyncUsn(a.cacheKey), 1);
      },
    );
  }

  test(
    'switch joins an independently running worker; stale epoch cannot restart',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      var calls = 0;
      final api = Api2Client(
        httpClient: MockClient((request) {
          calls++;
          expect(request.url.host, 'old.test');
          started.complete();
          return response.future;
        }),
      );
      final worker = SyncCoordinator(api, db);
      final ui = SyncCoordinator(api, db);
      final sessions = MemorySessions();
      await sessions.write(a.cacheKey, 'old-token');
      await sessions.write(b.cacheKey, 'new-token');
      final repo = AuthRepository(api, db, sessions, ui);
      final epoch = await SessionTransition.read(
        db.raw,
        SessionTransition.epochKey,
      );
      final task = worker.resetFromServer(account: a, token: 'old-token');
      final cancelled = expectLater(task, throwsA(isA<SyncCancelled>()));
      await started.future;
      final session = await repo
          .switchAccount(b.cacheKey)
          .timeout(const Duration(seconds: 3));
      await cancelled;
      expect(session.account.server, b.server);
      expect((await db.activeAccount())!.cacheKey, b.cacheKey);
      expect(worker.isBusy, false);
      await expectLater(
        runZoned(
          () => worker.synchronize(account: a, token: 'old-token'),
          zoneValues: {SessionTransition.expectedEpochKey: epoch},
        ),
        throwsA(isA<SyncCancelled>()),
      );
      response.complete(http.Response('{"LastSyncUsn":2}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);
      expect((await db.notes(a.cacheKey)).single.content, 'kept');
      expect((await db.activeAccount())!.cacheKey, b.cacheKey);
    },
  );

  test('logout cancels active sync and stale UI cannot restart it', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final api = Api2Client(
      httpClient: MockClient((_) {
        started.complete();
        return response.future;
      }),
    );
    final sync = SyncCoordinator(api, db);
    final sessions = MemorySessions();
    await sessions.write(a.cacheKey, 'old-token');
    final repo = AuthRepository(api, db, sessions, sync);
    final session = StoredSession(account: a, token: 'old-token');
    final task = repo.synchronizeFull(session);
    final assertion = expectLater(task, throwsA(isA<SyncCancelled>()));
    await started.future;
    await repo.logout(session);
    await assertion;
    expect(await repo.restore(), isNull);
    expect(await sessions.read(a.cacheKey), isNull);
    expect((await db.notes(a.cacheKey)).single.content, 'kept');
    await expectLater(repo.synchronize(session), throwsA(isA<SyncCancelled>()));
    response.complete(http.Response('{"LastSyncUsn":2}', 200));
  });

  test(
    'cancel immediately before replacing snapshot keeps dirty rows and cursor',
    () async {
      final draft = await db.createLocalNote(
        account: a,
        notebookId: '',
        isMarkdown: true,
        content: 'unsent',
      );
      final api = Api2Client(
        httpClient: MockClient(
          (request) async => http.Response(
            request.url.path.endsWith('getSyncState')
                ? '{"LastSyncUsn":2}'
                : '[]',
            200,
          ),
        ),
      );
      final sync = SyncCoordinator(api, db);
      Future<void>? stopping;
      await expectLater(
        sync.resetFromServer(
          account: a,
          token: 'old-token',
          onProgress: (p) {
            if (p.stage == SyncStage.saving) stopping = sync.cancel();
          },
        ),
        throwsA(isA<SyncCancelled>()),
      );
      await stopping;
      expect(await db.pendingNoteIds(a.cacheKey), {draft.noteId});
      expect(await db.lastSyncUsn(a.cacheKey), 1);
      expect((await db.notes(a.cacheKey)).length, 2);
    },
  );

  for (final cached in [true, false]) {
    test(
      'cancel login download keeps authentication and ${cached ? 'old' : 'empty'} cache',
      () async {
        final target = cached
            ? b
            : Account(
                userId: 'new-user',
                server: b.server,
                username: 'new',
                email: '',
                logo: '',
              );
        final started = Completer<void>();
        final response = Completer<http.Response>();
        final api = Api2Client(
          httpClient: MockClient((_) {
            started.complete();
            return response.future;
          }),
        );
        final repo = AuthRepository(
          api,
          db,
          MemorySessions(),
          SyncCoordinator(api, db),
        );
        final login = PendingLogin(
          session: StoredSession(account: target, token: 'new-token'),
          hasCache: cached,
        );
        final task = repo.completeLogin(login, resetCache: true);
        await started.future;
        await repo.cancelSync();
        final result = await task;
        expect(result.account.cacheKey, target.cacheKey);
        expect((await repo.restore())!.token, 'new-token');
        expect(await repo.autoSync(result), false);
        if (cached) {
          expect((await db.notes(target.cacheKey)).single.content, 'kept');
        } else {
          expect(await db.notes(target.cacheKey), isEmpty);
        }
        response.completeError(StateError('late transport error'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );
  }

  for (final streaming in [false, true]) {
    test(
      'aborts native HTTP while awaiting ${streaming ? 'body' : 'headers'}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final client = IOClient(HttpClient());
        final reached = Completer<void>();
        server.listen((request) async {
          if (streaming) {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"LastSyncUsn":');
            await request.response.flush();
          }
          reached.complete();
        });
        try {
          final cancellation = Cancellation();
          final api = Api2Client(httpClient: client);
          final task = cancellation.run(
            () => api.getSyncUsn(
              server: Uri.parse('http://127.0.0.1:${server.port}/'),
              token: 'test',
            ),
          );
          final assertion = expectLater(task, throwsA(isA<SyncCancelled>()));
          await reached.future;
          cancellation.cancel();
          await assertion.timeout(const Duration(seconds: 2));
        } finally {
          client.close();
          await server.close(force: true);
        }
      },
    );
  }
}
