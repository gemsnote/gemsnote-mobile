import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/login_page.dart';

class FailedDownloadRepository implements AuthRepository {
  @override
  Future<PendingLogin> beginLogin({
    required String serverAddress,
    required String identity,
    required String password,
  }) async => PendingLogin(
    hasCache: false,
    session: StoredSession(
      token: 'test-token',
      account: Account(
        userId: 'reader',
        server: Uri.parse(serverAddress),
        username: identity,
        email: '',
        logo: '',
      ),
    ),
  );
  @override
  Future<StoredSession> completeLogin(
    PendingLogin login, {
    required bool resetCache,
    SyncProgressCallback? onProgress,
  }) async => throw const ApiException('noteDownloadTimedOut');
  @override
  Future<void> cancelSync() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'login distinguishes successful authentication from failed sync: $language',
      (tester) async {
        var signedIn = false;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              AppStrings.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: LoginPage(
              repository: FailedDownloadRepository(),
              onSignedIn: (_) => signedIn = true,
            ),
          ),
        );
        final fields = find.byType(TextFormField);
        await tester.enterText(fields.at(0), 'https://notes.example.test');
        await tester.enterText(fields.at(1), 'reader');
        await tester.enterText(fields.at(2), 'fixture-password');
        final button = find.byType(FilledButton);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(signedIn, false);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.textContaining(
            language == 'zh' ? '账号验证成功' : 'Your account was verified',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            language == 'zh' ? '正文下载超时' : 'note bodies timed out',
          ),
          findsOneWidget,
        );
      },
    );
  }
}
