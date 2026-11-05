import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/account_switcher_page.dart';
import 'package:gemsnote/ui/login_page.dart';
import 'package:gemsnote/app.dart';
import 'package:gemsnote/ui/workspace_page.dart';

import 'foreground_sync_test.dart' show ForegroundRepository;

Account account(String host) => Account(
  userId: 'u',
  server: Uri.parse('https://$host/'),
  username: 'Same name',
  email: '',
  logo: '',
);
final a = account('one.test');
final b = account('two.test');

class SwitchRepository implements AuthRepository {
  bool readFails = false;
  bool switchFails = false;
  int switches = 0;
  Completer<void>? gate;
  @override
  Future<List<Account>> savedAccounts() async {
    if (readFails) throw StateError('read');
    return [a, b];
  }

  @override
  Future<StoredSession> switchAccount(String key) async {
    switches++;
    await gate?.future;
    if (switchFails) throw StateError('switch');
    return StoredSession(account: b, token: 'b');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RootSwitchRepository extends ForegroundRepository {
  @override
  Future<bool> appLockEnabled() async => false;
  @override
  Future<String> languagePreference() async => 'zh';

  bool loggedOut = false;
  @override
  Future<StoredSession?> restore() async =>
      loggedOut ? null : StoredSession(account: a, token: 'a');
  @override
  Future<List<Account>> savedAccounts() async => [a, b];
  @override
  Future<StoredSession> switchAccount(String key) async =>
      StoredSession(account: key == a.cacheKey ? a : b, token: key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('gemsnote/app_language'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('gemsnote/app_language'),
          null,
        );
  });
  testWidgets(
    'login screen restores another saved account without remote refresh',
    (tester) async {
      await tester.pumpWidget(
        GemsnoteApp(repository: RootSwitchRepository()..loggedOut = true),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择已登录账号'));
      await tester.tap(find.text('选择已登录账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('https://two.test/\nu'));
      await tester.pumpAndSettle();
      final workspace = tester.widget<WorkspacePage>(
        find.byType(WorkspacePage),
      );
      expect(workspace.session.account.cacheKey, b.cacheKey);
      expect(workspace.refreshAvatarOnStart, false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('account actions wait for previous resource queue to drain', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repo = SwitchRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountSwitcherPage(
          repository: repo,
          current: StoredSession(account: a, token: 'a'),
          beforeLoad: () => gate.future,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, true);
  });

  testWidgets('root creates fresh workspace on each account switch', (
    tester,
  ) async {
    await tester.pumpWidget(GemsnoteApp(repository: RootSwitchRepository()));
    await tester.pumpAndSettle();
    final original = tester.state(find.byType(WorkspacePage));
    for (final target in [b, a]) {
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换或添加账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('${target.server}\nu'));
      await tester.pumpAndSettle();
      final workspace = tester.widget<WorkspacePage>(
        find.byType(WorkspacePage),
      );
      expect(workspace.session.account.cacheKey, target.cacheKey);
      expect(tester.state(find.byType(WorkspacePage)), isNot(same(original)));
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'read retry, server identification, blocked back during switch and retry',
    (tester) async {
      final repo = SwitchRepository()..readFails = true;
      StoredSession? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await Navigator.push<StoredSession>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AccountSwitcherPage(
                        repository: repo,
                        current: StoredSession(account: a, token: 'a'),
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('读取账号失败，请重试'), findsOneWidget);
      repo.readFails = false;
      await tester.tap(find.text('重新读取账号'));
      await tester.pumpAndSettle();
      expect(find.text('https://one.test/\nu'), findsOneWidget);
      repo.gate = Completer<void>();
      repo.switchFails = true;
      await tester.tap(find.text('https://two.test/\nu'));
      await tester.pump();
      expect(
        tester.widget<ListTile>(find.byType(ListTile).last).enabled,
        false,
      );
      await tester.pageBack();
      await tester.pump();
      expect(find.byType(AccountSwitcherPage), findsOneWidget);
      repo.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('切换失败'), findsOneWidget);
      repo.switchFails = false;
      repo.gate = null;
      await tester.tap(find.text('https://two.test/\nu'));
      await tester.pumpAndSettle();
      expect(selected!.account.cacheKey, b.cacheKey);
      expect(repo.switches, 2);
    },
  );
  testWidgets(
    'adding account can be cancelled without switching existing session',
    (tester) async {
      final repo = SwitchRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: AccountSwitcherPage(
            repository: repo,
            current: StoredSession(account: a, token: 'a'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加账号'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsNothing);
      expect(repo.switches, 0);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );
}
