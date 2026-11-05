import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/email_verification.dart';

class MailRepository implements AuthRepository {
  int sends = 0;
  String? language;
  String state = 'queued';
  bool failStatus = false;
  @override
  Future<String?> pendingMailTask(StoredSession session) async => null;
  @override
  Future<Map<String, Object?>> queueVerification(
    StoredSession session, {
    bool current = false,
    String email = '',
    String password = '',
    required String language,
  }) async {
    sends++;
    this.language = language;
    expect(current, true);
    expect(password, isEmpty);
    return {'TaskId': 'task', 'State': 'queued', 'PendingEmail': ''};
  }

  @override
  Future<Map<String, Object?>> emailStatus(
    StoredSession session,
    String taskId,
  ) async {
    if (failStatus) throw StateError('offline');
    return {'State': state, if (state == 'failed') 'Error': 'SMTP rejected'};
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  for (final english in [false, true]) {
    testWidgets(
      'email resend requires confirmation, reports queue then failure; English=$english',
      (tester) async {
        final repo = MailRepository();
        final account = Account(
          userId: 'u',
          server: Uri.parse('https://example.test'),
          username: 'u',
          email: 'old@test.com',
          logo: '',
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(english ? 'en' : 'zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: EmailVerification(
                repository: repo,
                session: StoredSession(account: account, token: 'test'),
                account: account,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(english ? 'Email not verified' : '邮箱未验证'));
        await tester.pumpAndSettle();
        expect(repo.sends, 0);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(english ? 'Send verification email' : '发送验证邮件'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(repo.sends, 1);
        expect(repo.language, english ? 'en-US' : 'zh-CN');
        expect(
          find.text(english ? 'Verification email queued' : '验证邮件已加入发送队列'),
          findsOneWidget,
        );
        repo.state = 'failed';
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(
          find.text(
            AppStrings(Locale(english ? 'en' : 'zh')).text('errorGeneric'),
          ),
          findsOneWidget,
        );
        expect(find.text('SMTP rejected'), findsNothing);
        expect(find.textContaining('old@test.com'), findsOneWidget);
        expect(
          find.text(
            english
                ? 'Verification email sent. Please check your inbox.'
                : '验证邮件已发送，请查收',
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
