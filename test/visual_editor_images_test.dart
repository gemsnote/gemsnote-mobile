import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/visual_editor_images.dart';
import 'package:gemsnote/ui/visual_html_editor.dart';

final png = File('assets/images/gemsnote_s.png').readAsBytesSync();
const imageReference = '/api2/file/getImage?fileId=507f1f77bcf86cd799439011';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('image attributes preserve source and reject active or ambiguous markup', () {
    for (final source in [
      '<p>A<img src="$imageReference" alt="中 &amp; 文" width="120" height="80">B</p>',
      '<img src="https://outside.test/photo.png">',
      '<img src="/file/outputImage?fileId=507f1f77bcf86cd799439011">',
    ]) {
      expect(supportsVisualHtml(source), isTrue);
      expect(visualEditorDocument(source), contains("img-src data:"));
    }
    for (final attributes in [
      'src="javascript:alert(1)"',
      'src="data:image/png;base64,AAAA"',
      'src="file:///private/file"',
      'src="$imageReference" onerror="alert(1)"',
      'src="$imageReference" srcset="https://outside.test/file 2x"',
      'src="$imageReference" data-original-src="evil"',
      'src="$imageReference" width="99999"',
      'src="$imageReference" style="background:url(https://outside.test/a)"',
    ]) {
      expect(
        supportsVisualHtml('<img $attributes>'),
        isFalse,
        reason: attributes,
      );
    }
  });
  test('preview uses cache once per reference, validates images, and never rewrites source', () async {
    const source =
        '<img src="$imageReference"><img src="$imageReference"><img src="https://outside.test/photo.png">';
    final reads = <Uri>[];
    final images = await cachedVisualImages(source, (uri) async {
      reads.add(uri);
      return uri.hasScheme ? null : png;
    });
    expect(reads.length, 2);
    expect(images.keys, [imageReference]);
    expect(images[imageReference], startsWith('data:image/png;base64,'));
    expect(await visualImageData(Uint8List.fromList([1, 2, 3])), isNull);
    expect(
      await cachedVisualImages(
        source,
        (_) async => throw StateError('bad cache'),
      ),
      isEmpty,
    );
    final doc = visualEditorDocument(source, cachedImages: images);
    expect(doc, contains('document.head.appendChild(imageStyles)'));
    expect(doc, contains('changed ? editor.innerHTML : original'));
    expect(doc, contains('CSS.escape(src)'));
    expect(
      () => visualEditorDocument(
        source,
        cachedImages: {imageReference: 'https://outside.test/image'},
      ),
      throwsArgumentError,
    );
    expect(
      () => visualEditorDocument(
        source,
        cachedImages: {imageReference: 'data:image/svg+xml,<svg/>'},
      ),
      throwsArgumentError,
    );
  });
  test('cache traversal is bounded and stops after editor disposal', () async {
    final source = List.generate(
      40,
      (i) => '<img src="https://notes.test/$i.png">',
    ).join();
    var reads = 0;
    await cachedVisualImages(source, (_) async {
      reads++;
      return null;
    });
    expect(reads, 32);
    reads = 0;
    await cachedVisualImages(source, (_) async {
      reads++;
      return null;
    }, shouldContinue: () => reads < 2);
    expect(reads, 2);
  });
}
