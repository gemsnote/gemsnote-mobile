import 'dart:ui' show Locale;

import '../l10n/app_strings.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AvatarPicker {
  AvatarPicker({
    Future<PlatformFile?> Function()? pick,
    this.strings = const AppStrings(Locale('zh')),
  }) : _pick = pick ?? (() => _system(strings));
  final AppStrings strings;
  final Future<PlatformFile?> Function() _pick;
  static const maxBytes = 2 * 1024 * 1024;
  bool get cameraSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  Future<Uint8List?> capture() async {
    if (!cameraSupported) throw UnsupportedError('当前平台暂不支持拍照');
    final bytes = await const MethodChannel('gemsnote/avatar_camera')
        .invokeMethod<Uint8List>('capture');
    return bytes == null ? null : normalize(bytes, maxDimension: 1024);
  }

  static Future<PlatformFile?> _system(AppStrings strings) =>
      FilePicker.pickFile(
        dialogTitle: strings.label('选择头像'),
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
      );
  Future<Uint8List?> pick() async {
    final file = await _pick();
    if (file == null) return null;
    if ((file.lengthSync() ?? 0) > maxBytes) {
      throw const FormatException('头像不能超过 2 MiB');
    }
    final data = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream().timeout(
      const Duration(seconds: 30),
    )) {
      if (data.length + chunk.length > maxBytes) {
        throw const FormatException('头像不能超过 2 MiB');
      }
      data.add(chunk);
    }
    return normalize(data.takeBytes(), maxDimension: 1024);
  }

  static Future<Uint8List> normalize(
    Uint8List bytes, {
    int maxDimension = 256,
  }) async {
    if (maxDimension < 1 || maxDimension > 1024) {
      throw ArgumentError.value(maxDimension);
    }
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('头像大小无效');
    }
    final png =
        bytes.length >= 8 &&
        bytes.take(8).join(',') == '137,80,78,71,13,10,26,10';
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    final webp =
        bytes.length >= 12 &&
        String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
    final gif =
        bytes.length >= 6 &&
        {'GIF87a', 'GIF89a'}.contains(String.fromCharCodes(bytes.take(6)));
    final bmp = bytes.length >= 2 && bytes[0] == 66 && bytes[1] == 77;
    if (!png && !jpeg && !webp && !gif && !bmp) {
      throw const FormatException('请选择有效的 PNG、JPEG、WebP、GIF 或 BMP 图片');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > 4096 || descriptor.height > 4096) {
        throw const FormatException('头像尺寸不能超过 4096×4096');
      }
      final scale =
          maxDimension /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      codec = await descriptor.instantiateCodec(
        targetWidth: scale < 1
            ? (descriptor.width * scale).round().clamp(1, maxDimension)
            : descriptor.width,
        targetHeight: scale < 1
            ? (descriptor.height * scale).round().clamp(1, maxDimension)
            : descriptor.height,
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > maxBytes) {
        throw const FormatException('无法处理头像');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
