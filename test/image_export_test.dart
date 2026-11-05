import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/image_exporter.dart';

void main() {
  final formats = <String, List<int>>{
    'png': [137, 80, 78, 71, 13, 10, 26, 10],
    'jpg': [255, 216, 255, 224],
    'gif': [71, 73, 70, 56, 57, 97],
    'webp': [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80],
  };
  for (final entry in formats.entries) {
    test(
      'saves original ${entry.key} bytes with safe filename and actual MIME',
      () async {
        final content = Uint8List.fromList(entry.value);
        final exporter = ImageExporter(
          save: ({required fileName, required bytes, required mimeType}) async {
            expect(bytes, same(content));
            expect(fileName, '_photo.${entry.key}');
            expect(
              mimeType,
              'image/${entry.key == 'jpg' ? 'jpeg' : entry.key}',
            );
            return Uri.parse('content://documents/image');
          },
        );
        expect(await exporter.save('../photo.PNG', content), isTrue);
      },
    );
  }
  test('invalid, empty and oversized input never opens save dialog', () async {
    var calls = 0;
    final exporter = ImageExporter(
      save: ({required fileName, required bytes, required mimeType}) async {
        calls++;
        return null;
      },
    );
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([60, 104, 116, 109, 108]),
      Uint8List(8 * 1024 * 1024 + 1),
    ]) {
      await expectLater(exporter.save('image.png', bytes), throwsStateError);
    }
    expect(calls, 0);
  });
  test('cancel is not success and save errors propagate', () async {
    final bytes = Uint8List.fromList(formats['png']!);
    expect(
      await ImageExporter(
        save: ({required fileName, required bytes, required mimeType}) async =>
            null,
      ).save('', bytes),
      isFalse,
    );
    await expectLater(
      ImageExporter(
        save: ({required fileName, required bytes, required mimeType}) async =>
            throw StateError('disk full'),
      ).save('', bytes),
      throwsStateError,
    );
  });
}
