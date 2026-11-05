import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase db;
  final account = Account(
    userId: 'user',
    server: Uri.parse('https://notes.example.test/'),
    username: 'user',
    email: '',
    logo: '',
  );
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
  });
  tearDown(() => db.raw.close());

  test(
    'cross-stream changes after checkpoint are fetched on the next sync',
    () async {
      var round = 0;
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('getSyncState')) {
              round++;
              return http.Response(
                jsonEncode({'LastSyncUsn': round == 1 ? 10 : 13}),
                200,
              );
            }
            expect(
              request.url.queryParameters['afterUsn'],
              round == 1 ? '5' : '10',
            );
            if (path.endsWith('getSyncNotebooks')) {
              return http.Response(
                jsonEncode(
                  round == 1
                      ? []
                      : [
                          {
                            'NotebookId': 'book',
                            'Title': 'Moved during previous download',
                            'Usn': 11,
                          },
                        ],
                ),
                200,
              );
            }
            if (path.endsWith('getSyncNotesWithContent')) {
              return http.Response(
                jsonEncode([
                  {
                    'NoteId': 'note',
                    'Title': 'Note',
                    'Content': 'body',
                    'Usn': 12,
                  },
                ]),
                200,
              );
            }
            return http.Response(
              jsonEncode([
                {'Tag': 'tag', 'Usn': 13},
              ]),
              200,
            );
          }),
        ),
        db,
      );
      await sync.synchronize(account: account, token: 'test-token');
      expect(await db.lastSyncUsn(account.cacheKey), 10);
      expect(await db.notebooks(account.cacheKey), isEmpty);
      await sync.synchronize(account: account, token: 'test-token');
      expect((await db.notebooks(account.cacheKey)).single.usn, 11);
      expect(await db.lastSyncUsn(account.cacheKey), 13);
    },
  );

  test(
    'smaller body pages continue by USN without truncating the snapshot',
    () async {
      final cursors = <int>[];
      final received = <int>[];
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('getSyncState')) {
              return http.Response('{"LastSyncUsn":30}', 200);
            }
            if (!request.url.path.endsWith('getSyncNotesWithContent')) {
              return http.Response('[]', 200);
            }
            expect(request.url.queryParameters['maxEntry'], '10');
            final cursor = int.parse(request.url.queryParameters['afterUsn']!);
            cursors.add(cursor);
            return http.Response(
              jsonEncode(
                List.generate(
                  cursor == 0 ? 10 : 1,
                  (i) => {
                    'NoteId': 'n${cursor + i + 1}',
                    'UserId': account.userId,
                    'Usn': cursor + i + 1,
                    'Content': 'body ${cursor + i + 1}',
                  },
                ),
              ),
              200,
            );
          }),
        ),
        db,
      );
      await sync.downloadFreshSnapshot(
        account: account,
        token: 'test-token',
        onProgress: (value) {
          if (value.stage == SyncStage.notes) received.add(value.completed);
        },
      );
      expect(cursors, [0, 10]);
      expect(received, [0, 10, 11]);
      expect(await db.notes(account.cacheKey), hasLength(11));
      expect(
        (await db.notes(account.cacheKey))
            .firstWhere((n) => n.noteId == 'n11')
            .content,
        'body 11',
      );
      expect(await db.lastSyncUsn(account.cacheKey), 30);
    },
  );

  for (final endpoint in [
    'getSyncNotebooks',
    'getSyncNotesWithContent',
    'getSyncTags',
  ]) {
    test(
      'stalled $endpoint fails without committing partial data or cursor',
      () async {
        final sync = SyncCoordinator(
          Api2Client(
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('getSyncState')) {
                return http.Response('{"LastSyncUsn":10}', 200);
              }
              if (request.url.path.endsWith(endpoint)) {
                return http.Response(
                  jsonEncode(
                    List.generate(
                      endpoint == 'getSyncNotesWithContent'
                          ? Api2Client.syncNotePageSize
                          : 100,
                      (i) => {
                        'Usn': 5,
                        'NoteId': 'n$i',
                        'NotebookId': 'b$i',
                        'Tag': 't$i',
                      },
                    ),
                  ),
                  200,
                );
              }
              return http.Response('[]', 200);
            }),
          ),
          db,
        );
        await expectLater(
          sync.synchronize(account: account, token: 'test-token'),
          throwsStateError,
        );
        expect(await db.lastSyncUsn(account.cacheKey), 5);
        expect(await db.notebooks(account.cacheKey), isEmpty);
        expect(await db.notes(account.cacheKey), isEmpty);
      },
    );
  }

  test(
    'failed snapshot download retains existing cache and checkpoint',
    () async {
      var fail = true;
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('getSyncState')) {
              return http.Response('{"LastSyncUsn":10}', 200);
            }
            expect(request.url.queryParameters['afterUsn'], '0');
            if (request.url.path.endsWith('getSyncNotebooks')) {
              return http.Response('[{"NotebookId":"new","Usn":11}]', 200);
            }
            if (fail) {
              return http.Response('{"Ok":false,"Msg":"unavailable"}', 503);
            }
            return http.Response('[]', 200);
          }),
        ),
        db,
      );
      await expectLater(
        sync.downloadFreshSnapshot(account: account, token: 'test-token'),
        throwsException,
      );
      expect(await db.lastSyncUsn(account.cacheKey), 5);
      expect(await db.notebooks(account.cacheKey), isEmpty);
      fail = false;
      await sync.downloadFreshSnapshot(account: account, token: 'test-token');
      expect(await db.lastSyncUsn(account.cacheKey), 10);
      expect((await db.notebooks(account.cacheKey)).single.usn, 11);
    },
  );

  for (final state in [
    '{}',
    '{"LastSyncUsn":-1}',
    '{"LastSyncUsn":"bad"}',
    '{"LastSyncUsn":1.5}',
    '{"LastSyncUsn":3}',
  ]) {
    test('invalid or regressed sync state is rejected: $state', () async {
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            expect(request.url.path, '/api2/user/getSyncState');
            expect(request.method, 'GET');
            expect(request.headers.values, contains('Bearer test-token'));
            return http.Response(state, 200);
          }),
        ),
        db,
      );
      await expectLater(
        sync.synchronize(account: account, token: 'test-token'),
        state == '{"LastSyncUsn":3}'
            ? throwsStateError
            : throwsA(isA<ApiException>()),
      );
      expect(await db.lastSyncUsn(account.cacheKey), 5);
    });
  }
}
