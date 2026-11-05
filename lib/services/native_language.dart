import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<void> setNativeLanguage(String preference) async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)) {
    return;
  }
  await const MethodChannel('gemsnote/app_language')
      .invokeMethod<void>('setLanguage', {'language': preference})
      .timeout(const Duration(seconds: 5));
}
