import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:html/parser.dart' as html;

import 'cached_markdown_image.dart';

class VisualImageInsertion {
  const VisualImageInsertion(this.reference, this.png);
  final String reference;
  final Uint8List png;
}

/// Only decoded local bytes enter the isolated editor's presentation stylesheet.
/// Original image addresses remain in the body; data URLs never become content.
Future<String?> visualImageData(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 4096 || descriptor.height > 4096) return null;
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null || png.lengthInBytes > 8 * 1024 * 1024) return null;
    return 'data:image/png;base64,${base64Encode(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes))}';
  } on Exception {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<Map<String, String>> cachedVisualImages(
  String source,
  CachedImageLoader? load, {
  bool Function()? shouldContinue,
}) async {
  if (load == null) return {};
  final references = html
      .parseFragment(source)
      .querySelectorAll('img')
      .map((img) => img.attributes['src'])
      .whereType<String>()
      .toSet()
      .take(32);
  final result = <String, String>{};
  var remaining = 8 * 1024 * 1024;
  for (final reference in references) {
    if (shouldContinue?.call() == false) break;
    final uri = Uri.tryParse(reference);
    if (uri == null) continue;
    try {
      final bytes = await load(uri).timeout(const Duration(seconds: 2));
      if (bytes == null || bytes.length > remaining) continue;
      final data = await visualImageData(bytes);
      if (data == null || data.length > remaining) continue;
      remaining -= data.length;
      result[reference] = data;
    } on Object {
      // A missing/broken cache remains a placeholder, never a network fallback.
    }
  }
  return result;
}
