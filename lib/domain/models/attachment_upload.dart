import 'dart:typed_data';

class AttachmentUpload {
  AttachmentUpload({required this.name, required this.bytes}) {
    if (name.trim().isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[\\/\x00-\x1f\x7f]')) ||
        name.length > 255) {
      throw const FormatException('附件文件名无效');
    }
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('附件必须非空且不超过 32 MiB');
    }
  }
  static const maxBytes = 32 * 1024 * 1024;
  final String name;
  final Uint8List bytes;
}
