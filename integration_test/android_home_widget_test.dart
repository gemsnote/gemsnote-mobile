import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Run only through scripts/test_android_home_widget.py on a disposable emulator
// with a launcher widget already added. The host verifies RemoteViews and taps
// them; this side verifies the actual PendingIntent delivered to MainActivity.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('launcher widget isolates accounts and delivers real actions', (
    tester,
  ) async {
    expect(Platform.isAndroid, true);
    const run = String.fromEnvironment('WIDGET_TEST_RUN');
    expect(run, isNotEmpty);
    const channel = MethodChannel('gemsnote/home_widget');
    final a = 'widget-test-$run-a', b = 'widget-test-$run-b';
    const noteA = '507f1f77bcf86cd799439011';
    const noteB = '507f1f77bcf86cd799439012';

    Future<Map<String, dynamic>> activate(String account) async =>
        (await channel.invokeMapMethod<String, dynamic>('activate', {
          'account': account,
        }))!;
    Future<void> enable(String account, String epoch, bool value) =>
        channel.invokeMethod('setEnabled', {
          'account': account,
          'epoch': epoch,
          'enabled': value,
        });
    Future<void> publish(
      String account,
      String epoch,
      String id,
      String title,
    ) => channel.invokeMethod('publish', {
      'account': account,
      'epoch': epoch,
      'notes': [
        {'id': id, 'title': title},
      ],
    });
    Future<void> stage(
      String name,
      String account,
      String action, [
      String noteId = '',
    ]) async {
      // The host acts only after this marker; no timers stand in for UI checks.
      // ignore: avoid_print
      print('WIDGET_STAGE:$name');
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      Map<String, dynamic>? pending;
      while (DateTime.now().isBefore(deadline)) {
        pending = await channel.invokeMapMethod<String, dynamic>('peek');
        if (pending != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(pending, isNotNull, reason: 'No launcher action for $name');
      expect(pending!['account'], account);
      expect(pending['action'], action);
      expect(pending['noteId'], noteId);
      // Acknowledge must not discard a different, more recent action.
      await channel.invokeMethod<void>('acknowledge', {'id': 'unrelated'});
      expect((await channel.invokeMapMethod('peek'))!['id'], pending['id']);
      await channel.invokeMethod<void>('acknowledge', {'id': pending['id']});
      expect(await channel.invokeMapMethod('peek'), isNull);
    }

    try {
      final first = await activate(a);
      final epochA = first['epoch'] as String;
      expect(first['enabled'], false);
      // Even a caller publishing while disabled must not expose titles.
      await publish(a, epochA, noteA, 'Widget fixture A');
      await stage('private-a', a, 'home');
      await enable(a, epochA, true);
      await publish(a, epochA, noteA, 'Widget fixture A');
      await stage('list-a', a, 'open', noteA);
      await enable(a, epochA, false);
      await stage('disabled-a', a, 'home');
      await enable(a, epochA, true);
      await publish(a, epochA, noteA, 'Widget fixture A');

      final second = await activate(b);
      final epochB = second['epoch'] as String;
      expect(second['enabled'], false);
      await expectLater(
        publish(a, epochA, noteA, 'STALE TITLE'),
        throwsA(isA<PlatformException>()),
      );
      await stage('private-b', b, 'home');
      await enable(b, epochB, true);
      await publish(b, epochB, noteB, 'Widget fixture B');
      await stage('list-b', b, 'open', noteB);
      await stage('create-b', b, 'create');

      final returned = await activate(a);
      final newEpoch = returned['epoch'] as String;
      expect(returned['enabled'], true);
      expect(newEpoch, isNot(epochA));
      await expectLater(
        publish(a, epochA, noteA, 'STALE TITLE'),
        throwsA(isA<PlatformException>()),
      );
      await publish(a, newEpoch, noteA, 'Widget fixture A restored');
      await stage('restored-a', a, 'open', noteA);
      await activate('');
      await stage('logout', '', 'home');
    } finally {
      // Remove test titles and disable both fixture preferences, even on failure.
      for (final account in [a, b]) {
        final state = await activate(account);
        await enable(account, state['epoch'] as String, false);
      }
      await activate('');
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
