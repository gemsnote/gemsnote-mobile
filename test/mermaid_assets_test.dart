import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'offline Mermaid assets match the recorded version and content hash',
    () {
      final html = File('assets/mermaid/index.html').readAsBytesSync();
      final manifest = jsonDecode(
        File('assets/mermaid/manifest.json').readAsStringSync(),
      );
      expect(manifest['mermaid'], '11.17.2');
      expect(sha256.convert(html).toString(), manifest['sha256']);
      final text = utf8.decode(html);
      expect(text, contains("connect-src 'none'"));
      expect(text, contains("default-src 'none'"));
      expect(
        RegExp(r'<script\s+src=', caseSensitive: false).hasMatch(text),
        isFalse,
      );
      expect(
        File('assets/mermaid/LICENSE').readAsStringSync(),
        contains('MIT'),
      );
    },
  );
}
