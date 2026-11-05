import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/password_change_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  for (final scenario in ['ok', 'rejected']) {
    test(
      'password change checks account and does not retry: $scenario',
      () async {
        var writes = 0;
        final api = Api2Client(
          httpClient: MockClient((r) async {
            expect(r.followRedirects, false);
            expect(r.url.queryParameters, isEmpty);
            switch (r.url.path) {
              case '/api2/user/updatePwd':
                expect(r.headers.values, contains('Bearer test-token'));
                writes++;
                expect(Uri.splitQueryString(r.body), {
                  'oldPwd': 'old&pwd',
                  'pwd': 'new&pwd',
                });
                return http.Response(
                  jsonEncode({'Ok': scenario != 'rejected'}),
                  200,
                );
              default:
                fail('unexpected request');
            }
          }),
        );
        final change = api.changePassword(
          server: Uri.parse('https://notes.test'),
          token: 'test-token',
          userId: 'u',
          identity: 'u',
          oldPassword: 'old&pwd',
          password: 'new&pwd',
        );
        if (scenario == 'ok') {
          await change;
        } else {
          await expectLater(change, throwsA(isA<ApiException>()));
        }
        expect(writes, 1);
      },
    );
  }
  test('local signout after password change retains dirty notes and cached account', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    addTearDown(db.raw.close);
    final account = Account(
      userId: 'u',
      server: Uri.parse('https://notes.test'),
      username: 'u',
      email: '',
      logo: '',
    );
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 3,
    );
    final note = await db.createLocalNote(
      account: account,
      notebookId: 'b',
      isMarkdown: true,
      content: 'unsynced',
    );
    final sessions = MemorySessions();
    await sessions.write(account.cacheKey, 'expired');
    final api = Api2Client(
      httpClient: MockClient((_) async => throw StateError('must not upload')),
    );
    final repo = AuthRepository(api, db, sessions, SyncCoordinator(api, db));
    await repo.logout(
      StoredSession(account: account, token: 'expired'),
      discardSessionWithPendingChanges: true,
    );
    expect(await sessions.read(account.cacheKey), isNull);
    expect(await db.pendingNoteIds(account.cacheKey), {note.noteId});
    expect((await db.notes(account.cacheKey)).single.content, 'unsynced');
    expect(await repo.restore(), isNull);
  });
  testWidgets(
    'password dialog checks confirmation and clears secrets after failure',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PasswordChangeDialog(
              identity: 'u',
              save: (identity, oldPassword, password) async {
                calls++;
                expect(oldPassword, 'old');
                expect(password, 'new');
                throw StateError('offline');
              },
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).at(1), 'old');
      await tester.enterText(find.byType(TextField).at(2), 'new');
      await tester.enterText(find.byType(TextField).at(3), 'wrong');
      await tester.tap(find.text('修改并退出登录'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('两次输入的新密码不一致'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(3), 'new');
      await tester.tap(find.text('修改并退出登录'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      for (var i = 1; i < 4; i++) {
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(i))
              .controller!
              .text,
          '',
        );
      }
      expect(find.textContaining('密码可能已修改'), findsOneWidget);
    },
  );
}
