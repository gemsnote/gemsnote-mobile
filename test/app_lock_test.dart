import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

import 'package:gemsnote/services/app_lock.dart';
import 'package:local_auth/local_auth.dart';

class _LocalAuthentication extends LocalAuthentication {
  bool? persistsAcrossBackgrounding;
  bool? onlyBiometrics;
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    persistsAcrossBackgrounding = persistAcrossBackgrounding;
    onlyBiometrics = biometricOnly;
    return true;
  }
}

class _Authenticator implements DeviceAuthenticator {
  _Authenticator({this.available = true});
  bool available;
  final responses = <bool>[];
  int calls = 0;
  bool supportFails = false;
  Completer<bool>? verification;

  @override
  Future<bool> supported() async {
    if (supportFails) throw StateError('biometric service unavailable');
    return available;
  }

  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    if (verification != null) return verification!.future;
    return responses.removeAt(0);
  }
}

void main() {
  test(
    'app lifecycle owns retries instead of native sticky authentication',
    () async {
      final native = _LocalAuthentication();
      expect(
        await LocalDeviceAuthenticator(native).authenticate('unlock'),
        true,
      );
      expect(native.persistsAcrossBackgrounding, false);
      expect(
        native.onlyBiometrics,
        false,
        reason: 'system passcode fallback remains available',
      );
    },
  );

  test('enabled lock protects cold start and foreground return', () async {
    final authenticator = _Authenticator()..responses.addAll([true, true]);
    bool saved = true;
    final lock = AppLockController(
      load: () async => saved,
      save: (value) async => saved = value,
      authenticator: authenticator,
    );
    addTearDown(lock.dispose);
    await lock.initialize('unlock');
    expect(lock.enabled, isTrue);
    expect(lock.locked, isFalse);
    lock.backgrounded();
    expect(lock.locked, isTrue);
    expect(await lock.unlock('unlock'), isTrue);
    expect(lock.locked, isFalse);
    expect(authenticator.calls, 2);
  });

  test('cancelled authentication never enables or unlocks the app', () async {
    final authenticator = _Authenticator()..responses.addAll([false, false]);
    bool saved = false;
    final lock = AppLockController(
      load: () async => saved,
      save: (value) async => saved = value,
      authenticator: authenticator,
    );
    addTearDown(lock.dispose);
    await lock.initialize('unlock');
    expect(await lock.setEnabled(true, 'enable'), isFalse);
    expect(saved, isFalse);
    expect(lock.enabled, isFalse);

    saved = true;
    final restored = AppLockController(
      load: () async => saved,
      save: (value) async => saved = value,
      authenticator: authenticator,
    );
    addTearDown(restored.dispose);
    await restored.initialize('unlock');
    expect(restored.enabled, isTrue);
    expect(restored.locked, isTrue);
  });

  test('logout cleanup disables the saved app lock', () async {
    final authenticator = _Authenticator()..responses.add(true);
    bool saved = true;
    final lock = AppLockController(
      load: () async => saved,
      save: (value) async => saved = value,
      authenticator: authenticator,
    );
    addTearDown(lock.dispose);
    await lock.initialize('unlock');
    await lock.clear();
    expect(saved, isFalse);
    expect(lock.enabled, isFalse);
    expect(lock.locked, isFalse);
  });

  test(
    'saved lock stays locked when device credentials become unavailable',
    () async {
      final lock = AppLockController(
        load: () async => true,
        save: (_) async {},
        authenticator: _Authenticator(available: false),
      );
      addTearDown(lock.dispose);
      await lock.initialize('unlock');
      expect(lock.supported, isFalse);
      expect(lock.enabled, isTrue);
      expect(lock.locked, isTrue);
      expect(await lock.unlock('unlock'), isFalse);
    },
  );

  test(
    'preference read failure hides content until settings can be read',
    () async {
      var failLoad = true;
      final authenticator = _Authenticator()..responses.add(true);
      final lock = AppLockController(
        load: () async {
          if (failLoad) throw StateError('database unavailable');
          return true;
        },
        save: (_) async {},
        authenticator: authenticator,
      );
      addTearDown(lock.dispose);
      await lock.initialize('unlock');
      expect(lock.locked, isTrue);
      expect(lock.error, 'appLockLoadFailed');
      expect(authenticator.calls, 0);
      failLoad = false;
      expect(await lock.unlock('unlock'), isTrue);
      expect(authenticator.calls, 1);
    },
  );

  test(
    'saved lock survives support probe exceptions and recovers on retry',
    () async {
      final authenticator = _Authenticator()..supportFails = true;
      final lock = AppLockController(
        load: () async => true,
        save: (_) async {},
        authenticator: authenticator,
      );
      addTearDown(lock.dispose);
      await lock.initialize('unlock');
      expect(lock.locked, isTrue);
      expect(lock.enabled, isTrue);
      authenticator.supportFails = false;
      authenticator.responses.add(true);
      expect(await lock.unlock('unlock'), isTrue);
    },
  );

  test(
    'disabled preference does not require credentials on unsupported device',
    () async {
      final lock = AppLockController(
        load: () async => false,
        save: (_) async {},
        authenticator: _Authenticator(available: false),
      );
      addTearDown(lock.dispose);
      await lock.initialize('unlock');
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
    },
  );

  test(
    'repeated unlock taps issue only one system authentication request',
    () async {
      final authenticator = _Authenticator()..responses.add(false);
      final lock = AppLockController(
        load: () async => true,
        save: (_) async {},
        authenticator: authenticator,
      );
      addTearDown(lock.dispose);
      await lock.initialize('unlock');
      final response = Completer<bool>();
      authenticator.verification = response;
      final first = lock.unlock('unlock');
      expect(await lock.unlock('unlock'), isFalse);
      response.complete(true);
      expect(await first, isTrue);
      expect(authenticator.calls, 2);
    },
  );
}
