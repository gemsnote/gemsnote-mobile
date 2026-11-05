import 'dart:ui' show Locale;

import '../l10n/app_strings.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';

/// Decoded and re-encoded PNG, without metadata or executable SVG content.
class NoteImageUpload {
  NoteImageUpload._(Uint8List data) : bytes = data.asUnmodifiableView();
  final Uint8List bytes;
  static const maxBytes = 8 * 1024 * 1024;

  static Future<NoteImageUpload> normalize(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('图片必须非空且不超过 8 MiB');
    }
    final png =
        bytes.length >= 8 &&
        bytes.take(8).join(',') == '137,80,78,71,13,10,26,10';
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if (!png && !jpeg) throw const FormatException('请选择 PNG 或 JPEG 图片');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > 4096 || descriptor.height > 4096) {
        throw const FormatException('图片尺寸不能超过 4096×4096');
      }
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > maxBytes) {
        throw const FormatException('转换后的 PNG 图片不能超过 8 MiB');
      }
      return NoteImageUpload._(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

class NoteImagePicker {
  NoteImagePicker({
    Future<PlatformFile?> Function()? pick,
    this.strings = const AppStrings(Locale('zh')),
  }) : _pick = pick ?? (() => _system(strings));
  final AppStrings strings;
  final Future<PlatformFile?> Function() _pick;
  static Future<PlatformFile?> _system(AppStrings strings) =>
      FilePicker.pickFile(
        dialogTitle: strings.label('选择正文图片'),
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg'],
      );

  Future<NoteImageUpload?> pick() async {
    final file = await _pick();
    if (file == null) return null;
    if ((file.lengthSync() ?? 0) > NoteImageUpload.maxBytes) {
      throw const FormatException('图片不能超过 8 MiB');
    }
    final data = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream().timeout(
      const Duration(seconds: 30),
    )) {
      if (data.length + chunk.length > NoteImageUpload.maxBytes) {
        throw const FormatException('图片不能超过 8 MiB');
      }
      data.add(chunk);
    }
    return NoteImageUpload.normalize(data.takeBytes());
  }
}
