import 'dart:io';

import 'package:integration_test/integration_test.dart';

import '../test/app_lock_gate_test.dart' as app_lock;
import 'native_smoke_test.dart' as native;

/// Native storage/WebView smoke checks plus production lock/navigation widgets.
/// Authentication is simulated by the shared lock scenario; this does not
/// exercise Android's biometric prompt or change the device's screen lock.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) {
    throw UnsupportedError('This runtime suite requires Android.');
  }
  native.main();
  app_lock.main();
}
