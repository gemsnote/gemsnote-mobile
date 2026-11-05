import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/account_page.dart';
import 'package:gemsnote/ui/password_change_dialog.dart';

class PasswordRepository implements AuthRepository {
  @override
  Future<String?> pendingMailTask(StoredSession session) async => null;
  var changes = 0;
  var logouts = 0;
  @override
  Future<Account> cachedProfile(StoredSession session) async => session.account;
  @override
  Future<Uint8List?> cachedAvatar(StoredSession session) async => null;
  @override
  Future<void> changePassword(
    StoredSession session, {
    required String identity,
    required String oldPassword,
    required String password,
  }) async {
    changes++;
  }

  @override
  Future<void> logout(
    StoredSession session, {
    bool discardSessionWithPendingChanges = false,
  }) async {
    expect(discardSessionWithPendingChanges, true);
    logouts++;
    if (logouts == 1) throw StateError('keychain unavailable');
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
    'successful password write with failed local cleanup retries only cleanup',
    (tester) async {
      final repo = PasswordRepository();
      final session = StoredSession(
        account: Account(
          userId: 'u',
          server: Uri.parse('https://notes.test'),
          username: 'u',
          email: '',
          logo: '',
        ),
        token: 'old',
      );
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          AccountPage(repository: repo, session: session),
                    ),
                  );
                },
                child: const Text('account'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('account'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('修改密码'),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('修改密码'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改密码'));

      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(PasswordChangeDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(1), 'old');
      await tester.enterText(fields.at(2), 'new');
      await tester.enterText(fields.at(3), 'new');
      await tester.tap(find.text('修改并退出登录'));
      await tester.pumpAndSettle();
      expect(find.byType(PasswordChangeDialog), findsNothing);
      expect(repo.changes, 1);
      expect(repo.logouts, 1);
      expect(find.textContaining('本机登录状态清理失败'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('返回登录'));
      await tester.pumpAndSettle();
      expect(repo.changes, 1);
      expect(repo.logouts, 2);
      expect(result, true);
      expect(find.byType(AccountPage), findsNothing);
    },
  );
}
