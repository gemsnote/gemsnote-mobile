import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/services/app_lock.dart';
import 'package:gemsnote/ui/app_lock_gate.dart';

class _Device implements DeviceAuthenticator {
  bool accepted = true;
  int calls = 0;
  Completer<bool>? pending;
  @override
  Future<bool> supported() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return pending?.future ?? accepted;
  }
}

void main() {
  for (final completesBeforePause in [true, false]) {
    testWidgets(
      'authentication return does not request a second unlock; completed before pause=$completesBeforePause',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final result = Completer<bool>();
        final device = _Device()..pending = result;
        final lock = AppLockController(
          load: () async => true,
          save: (_) async {},
          authenticator: device,
        );
        addTearDown(lock.dispose);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [AppStrings.delegate],
            locale: const Locale('en'),
            builder: (_, child) => AppLockGate(controller: lock, child: child!),
            home: const Scaffold(body: Text('private notebooks')),
          ),
        );
        await tester.pumpAndSettle();
        expect(device.calls, 1);
        expect(find.text('private notebooks'), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        if (completesBeforePause) {
          result.complete(true);
          await tester.pumpAndSettle();
        }
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        if (!completesBeforePause) {
          result.complete(true);
          await tester.idle();
        }
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(
          device.calls,
          1,
          reason: 'system authentication dismissal is not a new app return',
        );
        expect(find.text('private notebooks'), findsOneWidget);

        // A later genuine background must still lock immediately, with no
        // grace period that could expose notes after leaving the application.
        final next = Completer<bool>();
        device.pending = next;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(lock.locked, true);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(device.calls, 2);
        expect(find.text('private notebooks'), findsNothing);
        next.complete(true);
        await tester.pumpAndSettle();
        expect(find.text('private notebooks'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'cancelled system prompt waits for explicit retry instead of reopening on resume',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final result = Completer<bool>();
      final device = _Device()..pending = result;
      final lock = AppLockController(
        load: () async => true,
        save: (_) async {},
        authenticator: device,
      );
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppStrings.delegate],
          locale: const Locale('en'),
          builder: (_, child) => AppLockGate(controller: lock, child: child!),
          home: const Scaffold(body: Text('private notebooks')),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      result.complete(false);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(device.calls, 1);
      expect(find.text('private notebooks'), findsNothing);
      expect(find.text('Authentication was cancelled.'), findsOneWidget);
      device.pending = null;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(device.calls, 2);
      expect(find.text('private notebooks'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lock covers pushed editor and dialogs, preserves draft and navigation',
    (tester) async {
      final device = _Device();
      final lock = AppLockController(
        load: () async => true,
        save: (_) async {},
        authenticator: device,
      );
      addTearDown(lock.dispose);
      final editor = TextEditingController();
      addTearDown(editor.dispose);
      final navigation = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigation,
          localizationsDelegates: const [AppStrings.delegate],
          locale: const Locale('en'),
          builder: (_, child) => AppLockGate(controller: lock, child: child!),
          home: const Scaffold(body: Text('workspace')),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        navigation.currentState!.push(
          MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextField(controller: editor),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const AlertDialog(content: Text('private dialog')),
                    ),
                    child: const Text('open dialog'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'unsaved draft');
      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();
      device.accepted = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(lock.locked, isTrue);
      // Paused apps do not draw frames. Check rendered privacy after resuming.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Gemsnote is locked'), findsOneWidget);
      expect(find.text('Authentication was cancelled.'), findsOneWidget);
      expect(find.text('private dialog'), findsNothing);
      device.accepted = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('private dialog'), findsOneWidget);
      navigation.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(editor.text, 'unsaved draft');
      expect(navigation.currentState!.canPop(), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'initial preference read failure exposes retry but no private content',
    (tester) async {
      var failing = true;
      final lock = AppLockController(
        load: () async {
          if (failing) throw StateError('read');
          return false;
        },
        save: (_) async {},
        authenticator: _Device(),
      );
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppStrings.delegate],
          locale: const Locale('en'),
          builder: (_, child) => AppLockGate(controller: lock, child: child!),
          home: const Scaffold(body: Text('private notes')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('private notes'), findsNothing);
      expect(
        find.text('Could not read app lock settings. Retry unlocking.'),
        findsOneWidget,
      );
      failing = false;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('private notes'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
