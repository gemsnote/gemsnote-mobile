import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/about_dialog.dart';
import 'package:gemsnote/ui/workspace_page.dart';

import 'account_avatar_widget_test.dart' show AvatarRepository;

void main() {
  testWidgets(
    'account menu opens installed version independently of protocol version',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Gemsnote',
        packageName: 'app.gemsnote',
        version: '2.3.4',
        buildNumber: '57',
        buildSignature: '',
      );
      final repo = AvatarRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(
              account: Account(
                userId: 'u',
                server: Uri.parse('https://example.test'),
                username: 'u',
                email: '',
                logo: '',
              ),
              token: 'test-token',
            ),
            onSignedOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileAboutDialog), findsOneWidget);
      expect(find.textContaining('应用版本：2.3.4'), findsOneWidget);
      expect(find.textContaining('构建号：57'), findsOneWidget);
      expect(find.text('API2 协议版本：1.0.0'), findsOneWidget);
      expect(find.text('退出'), findsNothing);
      expect(find.textContaining('基于 Leanote'), findsNothing);
      expect(find.text('Gemsnote Mobile'), findsOneWidget);
      expect(find.text('日积字句，终得珠玑。'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MobileAboutDialog),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(repo.refreshes, 0);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileAboutDialog), findsNothing);
      expect(find.text('所有笔记'), findsOneWidget);
    },
  );

  testWidgets('timeout allows retry and closing while loading is safe', (
    tester,
  ) async {
    var calls = 0;
    final first = Completer<PackageInfo>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MobileAboutDialog(
                  loadPackageInfo: () {
                    calls++;
                    return first.future;
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('正在读取应用版本…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('无法读取应用版本，请重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(calls, 2);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    first.complete(
      PackageInfo(appName: '', packageName: '', version: '', buildNumber: ''),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable version never masquerades as protocol version', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MobileAboutDialog(
          loadPackageInfo: () async => PackageInfo(
            appName: '',
            packageName: '',
            version: '',
            buildNumber: '',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('应用版本：未知'), findsOneWidget);
    expect(find.textContaining('构建号：未知'), findsOneWidget);
  });
}
