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

import 'cached_login_test.dart' show MemorySessions;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  for (final cached in [false, true]) {
    for (final failed in [false, true]) {
      test('two-stage login cached=$cached downloadFailure=$failed', () async {
        final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
        addTearDown(db.raw.close);
        final account = Account(
          userId: 'u',
          server: Uri.parse('https://notes.example.test/'),
          username: 'old',
          email: '',
          logo: '',
        );
        if (cached) {
          await db.replaceSnapshot(
            account: account,
            notebooks: [],
            notes: [],
            tags: [],
            lastSyncUsn: 5,
          );
          await db.createLocalNote(
            account: account,
            notebookId: 'local',
            isMarkdown: true,
          );
          await db.deactivate(account.cacheKey);
        }
        final sessions = MemorySessions();
        final paths = <String>[];
        final api = Api2Client(
          httpClient: MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/auth/login')) {
              return http.Response(
                jsonEncode({
                  'Ok': true,
                  'Token': 'new-token',
                  'User': {'UserId': 'u', 'Username': 'renamed'},
                  'Server': {
                    'Name': 'gemsnote',
                    'Version': '1.0.0',
                    'MinVersion': '',
                  },
                }),
                200,
              );
            }
            expect(request.method, 'GET');
            expect(request.headers.values, contains('Bearer new-token'));
            if (request.url.path.endsWith('getSyncState')) {
              return http.Response('{"LastSyncUsn":2}', 200);
            }
            expect(request.url.queryParameters['afterUsn'], '0');
            if (failed) {
              return http.Response('{"Ok":false,"Msg":"offline"}', 503);
            }
            if (request.url.path.endsWith('getSyncNotesWithContent')) {
              return http.Response(
                '[{"NoteId":"remote","Content":"body","Usn":2}]',
                200,
              );
            }
            return http.Response('[]', 200);
          }),
        );
        final repo = AuthRepository(
          api,
          db,
          sessions,
          SyncCoordinator(api, db),
        );
        final login = await repo.beginLogin(
          serverAddress: account.server.toString(),
          identity: 'renamed',
          password: 'test-password',
        );
        expect(login.hasCache, cached);
        expect(paths, ['/api2/auth/login']);
        expect(await repo.restore(), isNull);
        expect(sessions.values, isEmpty);
        final finish = repo.completeLogin(login, resetCache: cached);
        if (failed) {
          await expectLater(finish, throwsException);
          expect(await repo.restore(), isNull);
          expect(sessions.values, isEmpty);
          expect(await db.hasAccountCache(account.cacheKey), cached);
          if (cached) {
            expect(await db.pendingNoteIds(account.cacheKey), hasLength(1));
            // Recovery without another network request: keep the original cache.
            await repo.completeLogin(login, resetCache: false);
            expect((await repo.restore())?.account.username, 'renamed');
          }
        } else {
          await finish;
          expect((await repo.restore())?.token, 'new-token');
          expect((await db.notes(account.cacheKey)).single.noteId, 'remote');
          expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
        }
        expect(paths.where((path) => path == '/api2/auth/login'), hasLength(1));
      });
    }
  }
}
