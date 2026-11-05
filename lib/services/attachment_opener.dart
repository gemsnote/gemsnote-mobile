import 'dart:ui' show Locale;

import '../l10n/app_strings.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'note_exporter.dart';

class AttachmentOpenException implements Exception {
  const AttachmentOpenException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AttachmentOpener {
  AttachmentOpener({
    this.strings = const AppStrings(Locale('zh')),
    Future<Directory> Function()? temporaryDirectory,
    Future<OpenResult> Function(String)? open,
    DateTime Function()? now,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _open = open ?? ((file) => OpenFilex.open(file)),
       _now = now ?? DateTime.now;
  final AppStrings strings;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<OpenResult> Function(String) _open;
  final DateTime Function() _now;

  Future<void> open(
    String title,
    Uint8List bytes, {
    bool Function()? canOpen,
  }) async {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const AttachmentOpenException('附件超过 32 MiB');
    }
    if (canOpen?.call() == false) return;
    final root = Directory(
      path.join(
        (await _temporaryDirectory()).path,
        'gemsnote-open-attachments',
      ),
    );
    await root.create(recursive: true);
    // Only our own expired copies are removed. Never delete files immediately
    // after launch: another application may still be reading them.
    final cutoff = _now().subtract(const Duration(days: 1));
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory || !path.basename(item.path).startsWith('open-')) {
        continue;
      }
      try {
        if ((await item.stat()).modified.isBefore(cutoff)) {
          await item.delete(recursive: true);
        }
      } on FileSystemException {
        /* Best-effort cleanup. */
      }
    }
    final directory = await root.createTemp('open-');
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
    final file = File(path.join(directory.path, name));
    var handedOff = false;
    try {
      await file.writeAsBytes(bytes, flush: true);
      if (canOpen?.call() == false) return;
      // Once invoked, keep the copy even if the native result is uncertain.
      handedOff = true;
      final result = await _open(file.path);
      if (result.type != ResultType.done) {
        throw AttachmentOpenException(switch (result.type) {
          ResultType.noAppToOpen => '没有可打开此附件的应用，请安装对应应用或使用保存、分享',
          ResultType.permissionDenied => '系统拒绝打开附件，请使用保存或分享',
          ResultType.fileNotFound => '临时附件已失效，请重新打开',
          _ => '无法打开附件，请重试或使用保存、分享',
        });
      }
    } finally {
      if (!handedOff) {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          /* Best effort. */
        }
      }
    }
  }
}
