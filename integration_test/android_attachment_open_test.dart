import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/attachment_opener.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('ATTACHMENT_OPEN_RUN');
  const kind = String.fromEnvironment('ATTACHMENT_OPEN_KIND');
  test(
    'Android attachment opener hands exact files to a real viewer',
    () async {
      expect(Platform.isAndroid, isTrue);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(run), isTrue);
      expect(kind, anyOf('binary', 'empty'));
      debugPrint('ATTACHMENT_OPEN_STAGE:$kind');
      await AttachmentOpener().open(
        kind == 'binary' ? '../open-$run-附件?.BIN' : 'open-$run-empty.bin',
        Uint8List.fromList(kind == 'binary' ? [0, 1, 127, 128, 255] : []),
      );
      debugPrint('ATTACHMENT_OPEN_RETURNED:$kind');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
