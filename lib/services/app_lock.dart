import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

abstract interface class DeviceAuthenticator {
  Future<bool> supported();
  Future<bool> authenticate(String reason);
}

class LocalDeviceAuthenticator implements DeviceAuthenticator {
  LocalDeviceAuthenticator([LocalAuthentication? authentication])
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  @override
  Future<bool> supported() => _authentication.isDeviceSupported();

  @override
  Future<bool> authenticate(String reason) => _authentication.authenticate(
    localizedReason: reason,
    biometricOnly: false,
    sensitiveTransaction: true,
    // AppLockGate owns foreground retries. Native sticky authentication also
    // retries on Activity resume and can reopen a completed system prompt.
    persistAcrossBackgrounding: false,
  );
}

class AppLockController extends ChangeNotifier {
  AppLockController({
    required this.load,
    required this.save,
    DeviceAuthenticator? authenticator,
  }) : _authenticator = authenticator ?? LocalDeviceAuthenticator();

  @visibleForTesting
  final Future<bool> Function() load;
  @visibleForTesting
  final Future<void> Function(bool) save;
  final DeviceAuthenticator _authenticator;
  bool ready = false;
  bool supported = false;
  bool enabled = false;
  bool locked = false;
  bool authenticating = false;
  String? error;
  bool _preferenceLoaded = false;
  Future<void>? _initializing;
  bool _checkingSupport = false;

  Future<void> initialize(String reason) =>
      _initializing ??= _initialize(reason)
          .whenComplete(() => _initializing = null);

  Future<void> _initialize(String reason) async {
    if (_preferenceLoaded) return;
    try {
      final stored = await load();
      _preferenceLoaded = true;
      enabled = stored;
      locked = stored;
      ready = true;
      error = null;
      notifyListeners();
      if (!stored) {
        await _detectSupport();
        return;
      }
      supported = await _authenticator.supported();
      if (!supported) error = 'appLockUnavailable';
      notifyListeners();
      if (supported) await unlock(reason);
    } on Object {
      error = _preferenceLoaded ? 'appLockUnavailable' : 'appLockLoadFailed';
      ready = true;
      supported = false;
      // An unknown preference or temporarily unavailable authenticator must
      // never silently expose a previously protected session.
      enabled = true;
      locked = true;
      notifyListeners();
    }
  }

  Future<void> _detectSupport() async {
    try {
      supported = await _authenticator.supported();
    } on Object {
      supported = false;
    }
    notifyListeners();
  }

  Future<bool> setEnabled(bool value, String reason) async {
    if (!ready || !supported || authenticating) return false;
    if (value == enabled) return true;
    if (!await _verify(reason)) return false;
    try {
      await save(value);
      enabled = value;
      locked = false;
      error = null;
      notifyListeners();
      return true;
    } on Object {
      error = 'appLockSaveFailed';
      notifyListeners();
      return false;
    }
  }

  void backgrounded() {
    if (enabled && !authenticating) {
      locked = true;
      notifyListeners();
    }
  }

  Future<bool> unlock(String reason) async {
    if (!_preferenceLoaded) {
      await initialize(reason);
      return _preferenceLoaded && !locked;
    }
    if (authenticating || _checkingSupport) return false;
    if (!enabled) {
      locked = false;
      return true;
    }
    if (!supported) {
      _checkingSupport = true;
      try {
        supported = await _authenticator.supported();
      } on Object {
        supported = false;
      } finally {
        _checkingSupport = false;
      }
      if (!supported) {
        error = 'appLockUnavailable';
        notifyListeners();
        return false;
      }
    }
    final ok = await _verify(reason);
    if (ok) {
      locked = false;
      error = null;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _verify(String reason) async {
    if (authenticating) return false;
    authenticating = true;
    error = null;
    notifyListeners();
    try {
      final ok = await _authenticator.authenticate(reason);
      if (!ok) error = 'appLockCancelled';
      return ok;
    } on Object {
      error = 'appLockFailed';
      return false;
    } finally {
      authenticating = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    await save(false);
    _preferenceLoaded = true;
    enabled = false;
    locked = false;
    error = null;
    notifyListeners();
  }
}
