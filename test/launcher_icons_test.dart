import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  void expectPng(String path, int size, {required bool alpha}) {
    final bytes = File(path).readAsBytesSync();
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10], reason: path);
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(16), size, reason: path);
    expect(data.getUint32(20), size, reason: path);
    expect(bytes[25], alpha ? 6 : 2, reason: '$path PNG color type');
  }

  test('every declared iOS AppIcon has the correct opaque RGB dimensions', () {
    const directory = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final catalog = jsonDecode(
      File('$directory/Contents.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final item in catalog['images'] as List) {
      final points = double.parse((item['size'] as String).split('x').first);
      final scale = int.parse((item['scale'] as String).replaceAll('x', ''));
      expectPng(
        '$directory/${item['filename']}',
        (points * scale).round(),
        alpha: false,
      );
    }
  });

  test(
    'Android provides density-correct fallback and adaptive foreground icons',
    () {
      const directory = 'android/app/src/main/res';
      const sizes = {
        'mdpi': [48, 108],
        'hdpi': [72, 162],
        'xhdpi': [96, 216],
        'xxhdpi': [144, 324],
        'xxxhdpi': [192, 432],
      };
      for (final item in sizes.entries) {
        expectPng(
          '$directory/mipmap-${item.key}/ic_launcher.png',
          item.value[0],
          alpha: false,
        );
        expectPng(
          '$directory/mipmap-${item.key}/ic_launcher_foreground.png',
          item.value[1],
          alpha: true,
        );
      }
      final adaptive = File('$directory/mipmap-anydpi-v26/ic_launcher.xml')
          .readAsStringSync();
      expect(adaptive, contains('@mipmap/ic_launcher_foreground'));
      expect(adaptive, contains('@color/launcher_background'));
      expect(
        File('$directory/values/colors.xml').readAsStringSync(),
        contains('#193b35'),
      );
      expect(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        contains('android:roundIcon="@mipmap/ic_launcher"'),
      );
    },
  );
}
