import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/app.dart';
import 'package:gemsnote/app_bootstrap.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/app_startup.dart';
import 'package:gemsnote/ui/login_page.dart';
import 'package:gemsnote/ui/startup_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class StartupRepository implements AuthRepository {
  Completer<String>? language;
  Completer<StoredSession?>? session;
  bool failRestore = false;
  int restores = 0;

  @override
  Future<bool> appLockEnabled() async => false;
  @override
  Future<String> languagePreference() async =>
      language == null ? 'zh' : await language!.future;
  @override
  Future<StoredSession?> restore() async {
    restores++;
    if (failRestore) throw StateError('private failure details');
    return session == null ? null : await session!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
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

  testWidgets('first frame shows branding while initialization is pending', (
    tester,
  ) async {
    final ready = Completer<AuthRepository>();
    var calls = 0;
    await tester.pumpWidget(
      GemsnoteBootstrap(
        initialize: () {
          calls++;
          return ready.future;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(StartupPage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    expect(calls, 1);
    ready.complete(StartupRepository());
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(StartupPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed initialization offers a localized retry', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('zh')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    var calls = 0;
    await tester.pumpWidget(
      GemsnoteBootstrap(
        initialize: () async {
          if (++calls == 1) throw StateError('private failure details');
          return StartupRepository();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('无法初始化应用'), findsOneWidget);
    expect(find.textContaining('private failure details'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'session restores alongside language, but waits before showing login',
    (tester) async {
      final repository = StartupRepository()
        ..language = Completer<String>()
        ..session = Completer<StoredSession?>();
      await tester.pumpWidget(GemsnoteApp(repository: repository));
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.restores, 1);
      repository.session!.complete(null);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(StartupPage), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);
      repository.language!.complete('zh');
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(repository.restores, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('session read failure stays on startup and can retry', (
    tester,
  ) async {
    final repository = StartupRepository()..failRestore = true;
    await tester.pumpWidget(GemsnoteApp(repository: repository));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取本地登录状态'), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    repository.failRestore = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(repository.restores, 2);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'local services start in parallel and failed attempt closes its database',
    () async {
      final background = Completer<void>();
      final databaseReady = Completer<AppDatabase>();
      var backgroundStarted = false;
      var databaseStarted = false;
      final initialization = initializeApplication(
        initializeBackground: () {
          backgroundStarted = true;
          return background.future;
        },
        openDatabase: () {
          databaseStarted = true;
          return databaseReady.future;
        },
      );
      final failure = expectLater(initialization, throwsStateError);
      expect(backgroundStarted, isTrue);
      expect(databaseStarted, isTrue);
      background.completeError(StateError('scheduler unavailable'));
      final database = await AppDatabase.open(
        databasePath: inMemoryDatabasePath,
      );
      databaseReady.complete(database);
      await failure;
      expect(database.raw.isOpen, isFalse);
    },
  );
}
