import '../l10n/app_strings.dart';

import 'dart:typed_data';
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import 'note_exporter.dart';

class AttachmentSharer {
  AttachmentSharer({
    this.strings = const AppStrings(Locale('zh')),
    Future<ShareResult> Function(ShareParams)? share,
  }) : _share = share ?? SharePlus.instance.share;
  final AppStrings strings;
  final Future<ShareResult> Function(ShareParams) _share;

  Future<void> share(String title, Uint8List bytes, Rect origin) async {
    if (bytes.length > 32 * 1024 * 1024) throw StateError('附件超过 32 MiB');
    if (!origin.isFinite || origin.isEmpty) throw StateError('无效的分享位置');
    // Preserve a short extension even when the title must be truncated.
    final extension =
        RegExp(r'\.[a-zA-Z0-9]{1,16}$')
            .firstMatch(title.trim())
            ?.group(0)
            ?.toLowerCase() ??
        '';
    final name = NoteExporter.safeFileName(
      title,
      extension,
      fallback: strings.label('附件'),
    );
    final mime =
        const {
          '.pdf': 'application/pdf',
          '.txt': 'text/plain',
          '.md': 'text/markdown',
          '.png': 'image/png',
          '.jpg': 'image/jpeg',
          '.jpeg': 'image/jpeg',
          '.gif': 'image/gif',
          '.zip': 'application/zip',
          '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        }[extension] ??
        'application/octet-stream';
    await _share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: mime)],
        fileNameOverrides: [name],
        sharePositionOrigin: origin,
      ),
    );
    // The plugin manages a temporary file. Selecting a target is not delivery.
  }
}
