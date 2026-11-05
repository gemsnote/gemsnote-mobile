import 'dart:async';

import 'package:gemsnote/core/api/api_exception.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/app.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/l10n/language_controller.dart';
import 'package:gemsnote/l10n/messages.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/attachment_exporter.dart';
import 'package:gemsnote/services/native_language.dart';
import 'package:gemsnote/ui/login_page.dart';

class LanguageRepository implements AuthRepository {
  @override
  Future<bool> appLockEnabled() async => false;
  String preference = 'system';
  bool fail = false;
  @override
  Future<String> languagePreference() async => preference;
  @override
  Future<void> setLanguagePreference(String value) async {
    if (fail) throw StateError('disk full');
    preference = value;
  }

  @override
  Future<StoredSession?> restore() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  const english = AppStrings(Locale('en'));
  const chinese = AppStrings(Locale('zh'));
  test('API, runtime and platform errors use selected language without private details', () {
    expect(
      chinese.errorMessage(const ApiException('wrongUsernameOrPassword')),
      '用户名、邮箱或密码不正确。',
    );
    expect(
      english.errorMessage(const ApiException('wrongUsernameOrPassword')),
      'The username, email or password is incorrect.',
    );
    expect(
      chinese.errorMessage(const ApiException('NOTLOGIN')),
      contains('重新登录'),
    );
    expect(
      english.errorMessage(const ApiException('wrongPassword')),
      'The current password is incorrect.',
    );
    expect(
      chinese.errorMessage(StateError('syncInProgress')),
      contains('正在执行同步'),
    );
    expect(
      english.errorMessage(StateError('syncInProgress')),
      isNot(contains('Bad state')),
    );
    expect(
      chinese.errorMessage(
        PlatformException(
          code: 'plugin_error',
          message: 'raw native error',
          details: 'secret',
        ),
      ),
      '无法完成系统操作，请检查应用权限后重试。',
    );
    for (final strings in [chinese, english]) {
      expect(
        strings.errorMessage(Exception('https://old.test/?token=secret')),
        strings.text('errorGeneric'),
      );
      expect(
        strings.text('m0156', [const ApiException('NOTLOGIN')]),
        contains(strings.text('errorSession')),
      );
    }
  });
  test(
    'every catalog entry is generated, translated and preserves placeholders',
    () {
      final catalog = jsonDecode(
        File('tool/localization/messages.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(messages.keys.toSet(), catalog.keys.toSet());
      Set<String> placeholders(String value) =>
          RegExp(r'\{\d+\}').allMatches(value).map((m) => m[0]!).toSet();
      for (final entry in catalog.entries) {
        final zh = entry.value['zh'] as String;
        final en = entry.value['en'] as String;
        expect(zh.trim(), isNotEmpty, reason: entry.key);
        expect(en.trim(), isNotEmpty, reason: entry.key);
        expect(messages[entry.key], (zh, en), reason: entry.key);
        expect(placeholders(en), placeholders(zh), reason: entry.key);
      }
    },
  );
  test(
    'interpolated user content and braces are not translated or expanded',
    () {
      final key = messages.entries
          .firstWhere((e) => e.value.$1.contains('{0}'))
          .key;
      final source = '取消 {1} 笔记原文';
      expect(english.text(key, [source]), contains(source));
      expect(english.label('a user-defined title'), 'a user-defined title');
      final errorKey = messages.entries
          .firstWhere((e) => e.value.$1.contains('{0}'))
          .key;
      expect(
        english.text(errorKey, [StateError('附件超过 32 MiB')]),
        contains('32 MiB'),
      );
      expect(
        english.text(errorKey, [StateError('附件超过 32 MiB')]),
        isNot(contains('附件')),
      );
      expect(english.translateMessage('选择附件'), 'Choose attachment');
      expect(chinese.translateMessage('Choose attachment'), '选择附件');
    },
  );
  test('late restore cannot replace a saved choice; native failure remains retryable', () async {
    final read = Completer<String>();
    bool nativeFails = true;
    final nativeValues = <String>[];
    final controller = LanguageController(
      load: () => read.future,
      save: (_) async {},
      applyNative: (value) async {
        nativeValues.add(value);
        if (nativeFails) throw StateError('native failed');
      },
    );
    final restore = controller.restore();
    await controller.choose('en');
    read.complete('zh');
    await restore;
    expect(controller.preference, 'en');
    expect(controller.ready, isTrue);
    expect(controller.nativeError, isNotNull);
    nativeFails = false;
    await controller.refreshNative();
    expect(controller.nativeError, isNull);
    expect(nativeValues, ['en', 'en']);
    controller.dispose();
  });
  test(
    'save failure retains preference; disposal ignores late results',
    () async {
      final gate = Completer<void>();
      final controller = LanguageController(
        load: () async => 'zh',
        save: (value) =>
            value == 'en' ? Future.error(StateError('disk full')) : gate.future,
      );
      await controller.restore();
      await expectLater(controller.choose('en'), throwsStateError);
      expect(controller.preference, 'zh');
      final pending = controller.choose('system');
      controller.dispose();
      gate.complete();
      await pending;
      expect(controller.preference, 'zh');
    },
  );
  test('localized exports preserve actual names and bytes', () async {
    String? name;
    Uint8List? output;
    final exporter = AttachmentExporter(
      strings: english,
      save: ({required fileName, required bytes, required mimeType}) async {
        name = fileName;
        output = bytes;
        return Uri.parse('content://saved/file');
      },
    );
    final bytes = Uint8List.fromList([1, 2, 3]);
    await exporter.save('', bytes);
    expect(name, 'Attachment');
    expect(output, bytes);
    await exporter.save('取消.txt', bytes);
    expect(name, '取消.txt');
  });
  testWidgets('system fallback, live language choice and restart persistence', (
    tester,
  ) async {
    final repo = LanguageRepository();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('fr')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(GemsnoteApp(repository: repo));
    await tester.pumpAndSettle();
    BuildContext login() => tester.element(find.byType(LoginPage));
    expect(AppStrings.of(login()).locale.languageCode, 'en');
    tester.binding.platformDispatcher.localesTestValue = const [
      Locale('zh', 'TW'),
    ];
    await tester.pumpAndSettle();
    expect(AppStrings.of(login()).locale.languageCode, 'zh');
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(repo.preference, 'en');
    expect(AppStrings.of(login()).locale.languageCode, 'en');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(GemsnoteApp(repository: repo));
    await tester.pumpAndSettle();
    expect(AppStrings.of(login()).locale.languageCode, 'en');
    repo.fail = true;
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文 (Chinese)'));
    await tester.pumpAndSettle();
    expect(repo.preference, 'en');
    expect(find.textContaining('Storage is full'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('language dialog fits a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    await tester.pumpWidget(
      GemsnoteApp(repository: LanguageRepository()..preference = 'en'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('native bridge sends locale preference on Android and iOS', (
    tester,
  ) async {
    final values = <Object?>[];
    const channel = MethodChannel('gemsnote/app_language');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      values.add(call.arguments);
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await setNativeLanguage('en');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await setNativeLanguage('zh');
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await setNativeLanguage('system');
    debugDefaultTargetPlatformOverride = null;
    expect(values, [
      {'language': 'en'},
      {'language': 'zh'},
    ]);
  });
}
