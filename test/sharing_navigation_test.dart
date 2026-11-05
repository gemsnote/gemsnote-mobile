import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/shared_note.dart';
import 'package:gemsnote/domain/models/sharing_navigation.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  const user = '507f1f77bcf86cd799439011',
      owner = '507f1f77bcf86cd799439012',
      noteId = '507f1f77bcf86cd799439013',
      bookId = '507f1f77bcf86cd799439014';
  final server = Uri.parse('https://example.test/');
  final account = Account(
    userId: user,
    server: server,
    username: 'Reader',
    email: 'old@test.com',
    logo: '',
    verified: true,
    pendingEmail: 'new@test.com',
  );
  final session = StoredSession(account: account, token: 'secret');
  final shared = SharedNote.fromJson({
    'NoteId': noteId,
    'OwnerUserId': owner,
    'Title': 'Shared',
    'IsMarkdown': true,
    'Version': 'a' * 64,
  });
  final book = Notebook.fromJson({
    'NotebookId': bookId,
    'Title': 'Mine',
    'Usn': 1,
  });
  late AppDatabase db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [book],
      notes: [],
      tags: [],
      lastSyncUsn: 1,
    );
    await db.replaceSharedSnapshot(account.cacheKey, [shared]);
  });
  tearDown(() => db.raw.close());
  AuthRepository repository(http.Client client) {
    final api = Api2Client(httpClient: client);
    return AuthRepository(api, db, MemorySessions(), SyncCoordinator(api, db));
  }

  test('move uses original server IDs and only changes recipient placement; revoked cache vanishes', () async {
    final repo = repository(
      MockClient((req) async {
        expect(req.url.path, '/api2/shared/move');
        expect(req.method, 'POST');
        expect(req.headers['authorization'], 'Bearer secret');
        expect(jsonDecode(req.body), {'noteId': noteId, 'notebookId': bookId});
        return http.Response('{"Ok":true}', 200);
      }),
    );
    await repo.moveSharedNote(session, shared, bookId);
    final displayed = (await repo.notes(
      account.cacheKey,
      notebookId: bookId,
    )).single;
    expect(displayed.noteId, noteId);
    expect(displayed.isShared, true);
    expect(displayed.userId, owner);
    expect((await repo.notebooks(account.cacheKey)).single.numberNotes, 1);
    expect(await db.notes(account.cacheKey), isEmpty);
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
    expect(
      (await db.cachedSharedNotes(account.cacheKey)).single.note.notebookId,
      isNot(bookId),
    );
    expect(await repo.notes('other-server#$user'), isEmpty);
    await db.replaceSharedSnapshot(account.cacheKey, []);
    expect(await repo.notes(account.cacheKey), isEmpty);
    expect((await repo.notebooks(account.cacheKey)).single.numberNotes, 0);
  });
  test('failed move retains placement and unsynced destinations never request server', () async {
    var calls = 0;
    final repo = repository(
      MockClient((req) async {
        calls++;
        return http.Response('{"Ok":false,"Msg":"noPermission"}', 403);
      }),
    );
    await expectLater(
      repo.moveSharedNote(session, shared, bookId),
      throwsA(isA<ApiException>()),
    );
    expect((await repo.sharingNavigation(session)).placements, isEmpty);
    await expectLater(
      repo.moveSharedNote(session, shared, '507f1f77bcf86cd799439099'),
      throwsA(isA<ApiException>()),
    );
    expect(calls, 1);
  });
  test('profile verification survives restore and account switching, keeps old email', () async {
    expect((await db.activeAccount())!.verified, true);
    expect((await db.activeAccount())!.pendingEmail, 'new@test.com');
    await db.activateCachedAccount((await db.cachedAccounts()).single);
    final restored = await db.cachedProfile(account);
    expect(restored.verified, true);
    expect(restored.email, 'old@test.com');
    expect(restored.pendingEmail, 'new@test.com');
  });
  test(
    'expired mail task clears pending state so verification can be retried',
    () async {
      await db.setAccountMetadata(account.cacheKey, 'mail-task', {
        'TaskId': 'expired',
      });
      final repo = repository(
        MockClient(
          (request) async =>
              http.Response('{"Ok":false,"Msg":"mailTaskNotFound"}', 200),
        ),
      );
      expect((await repo.emailStatus(session, 'expired'))['State'], 'failed');
      expect(await repo.pendingMailTask(session), null);
      expect((await db.cachedProfile(account)).email, 'old@test.com');
    },
  );
  test(
    'historical suggestions survive serialization without active shares',
    () {
      final data = {
        'Suggestions': [
          {'UserId': user, 'Username': 'renamed', 'NoteIds': <String>[]},
        ],
      };
      final nav = SharingNavigation.fromJson(
        SharingNavigation.fromJson(data).toJson(),
      );
      expect(nav.recipients, isEmpty);
      expect(nav.suggestions.single.username, 'renamed');
    },
  );
  test('outgoing recipients and placements validate IDs and round trip', () {
    final navigation = SharingNavigation.fromJson({
      'Recipients': [
        {
          'UserId': user,
          'Username': 'Reader',
          'NoteIds': [noteId],
        },
      ],
      'Placements': {noteId: bookId},
    });
    expect(
      SharingNavigation.fromJson(navigation.toJson()).recipientsFor(noteId),
      ['Reader'],
    );
    expect(
      () => SharingNavigation.fromJson({
        'Placements': {'bad': bookId},
      }),
      throwsFormatException,
    );
  });
  test(
    'share and revoke use API2 form contract and per-email failure is surfaced',
    () async {
      var fail = false;
      final api = Api2Client(
        httpClient: MockClient((req) async {
          expect(req.headers['authorization'], 'Bearer secret');
          expect(req.method, 'POST');
          final body = Uri.splitQueryString(req.body);
          expect(
            req.headers['content-type'],
            startsWith('application/x-www-form-urlencoded'),
          );
          expect(body['noteId'], noteId);
          switch (req.url.path) {
            case '/api2/web/shareMembers':
              return http.Response('{"Users":[]}', 200);
            case '/api2/share/addShareNote':
              expect(body['emails[0]'], 'reader@test.com');
              expect(body['perm'], '0');
              return http.Response(
                jsonEncode({
                  'reader@test.com': {'Ok': !fail, 'Msg': 'notExists'},
                }),
                200,
              );
            case '/api2/share/deleteShareNote':
              expect(body['toUserId'], user);
              return http.Response('true', 200);
            default:
              throw StateError(req.url.path);
          }
        }),
      );
      await api.shareMembers(server: server, token: 'secret', noteId: noteId);
      await api.shareNote(
        server: server,
        token: 'secret',
        noteId: noteId,
        email: 'reader@test.com',
      );
      fail = true;
      await expectLater(
        api.shareNote(
          server: server,
          token: 'secret',
          noteId: noteId,
          email: 'reader@test.com',
        ),
        throwsA(isA<ApiException>()),
      );
      await api.revokeNoteShare(
        server: server,
        token: 'secret',
        noteId: noteId,
        userId: user,
      );
    },
  );
  test('mail task persists by server+user, sends language, clears on delivery failure without changing email', () async {
    final repo = repository(
      MockClient((req) async {
        expect(req.headers['authorization'], 'Bearer secret');
        final fields = Uri.splitQueryString(req.body);
        if (req.url.path == '/api2/web/emailChange') {
          expect(fields, {'email': 'new@test.com', 'pwd': 'p&ss'});
          expect(req.headers['accept-language'], 'en-US');
          return http.Response(
            '{"Ok":true,"TaskId":"task","State":"queued","PendingEmail":"new@test.com"}',
            200,
          );
        }
        expect(req.url.path, '/api2/user/emailStatus');
        expect(fields, {'taskId': 'task'});
        return http.Response('{"State":"failed","Error":"smtpFailed"}', 200);
      }),
    );
    await repo.queueVerification(
      session,
      email: 'new@test.com',
      password: 'p&ss',
      language: 'en-US',
    );
    expect(await repo.pendingMailTask(session), 'task');
    expect((await db.cachedProfile(account)).email, 'old@test.com');
    expect(await db.accountMetadata('other', 'mail-task'), isEmpty);
    expect((await repo.emailStatus(session, 'task'))['State'], 'failed');
    expect(await repo.pendingMailTask(session), null);
  });
}
