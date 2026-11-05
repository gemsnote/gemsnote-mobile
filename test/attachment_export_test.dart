import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/attachment_exporter.dart';

void main() {
  test('sanitizes filename and saves exact bytes', () async {
    final bytes = Uint8List.fromList([0, 255, 1]);
    final exporter = AttachmentExporter(
      save: ({required fileName, required bytes, required mimeType}) async {
        expect(fileName, '_report.pdf');
        expect(bytes, [0, 255, 1]);
        expect(mimeType, 'application/octet-stream');
        return Uri.parse('content://saved/file');
      },
    );
    expect(await exporter.save('../report.pdf', bytes), isTrue);
  });
  test(
    'empty attachment valid, cancel not success, oversize rejected',
    () async {
      var calls = 0;
      final exporter = AttachmentExporter(
        save: ({required fileName, required bytes, required mimeType}) async {
          calls++;
          expect(fileName, '附件');
          return null;
        },
      );
      expect(await exporter.save('', Uint8List(0)), isFalse);
      await expectLater(
        exporter.save('', Uint8List(32 * 1024 * 1024 + 1)),
        throwsStateError,
      );
      expect(calls, 1);
    },
  );
}
