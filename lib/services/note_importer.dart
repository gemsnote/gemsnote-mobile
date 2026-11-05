import '../domain/models/note_bundle.dart';
import 'rich_document.dart';

import 'dart:ui' show Locale;

import '../l10n/app_strings.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

class ImportedNote {
  const ImportedNote(
    this.title,
    this.content,
    this.isMarkdown, {
    this.bundle,
    this.warning,
  });
  final NoteBundle? bundle;
  final String? warning;
  final String title;
  final String content;
  final bool isMarkdown;
}

class NoteImporter {
  NoteImporter({
    Future<PlatformFile?> Function()? pick,
    this.strings = const AppStrings(Locale('zh')),
  }) : _pick = pick ?? (() => _pickSystem(strings));
  final AppStrings strings;
  final Future<PlatformFile?> Function() _pick;
  static const maxBytes = 32 * 1024 * 1024;
  static Future<PlatformFile?> _pickSystem(AppStrings strings) {
    // Android converts extension filters to known MIME types. A .gemsnote
    // archive is not registered and becomes unselectable in DocumentsUI.
    // Validate the selected name and bounded content below instead.
    final android = defaultTargetPlatform == TargetPlatform.android;
    return FilePicker.pickFile(
      dialogTitle: strings.label('导入笔记原文'),
      type: android ? FileType.any : FileType.custom,
      allowedExtensions: android
          ? null
          : ['md', 'markdown', 'txt', 'html', 'htm', 'rtf', 'docx', 'gemsnote'],
    );
  }

  Future<ImportedNote?> pick() async {
    final file = await _pick();
    if (file == null) return null;
    final name = file.name.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (![
      'md',
      'markdown',
      'txt',
      'html',
      'htm',
      'rtf',
      'docx',
      'gemsnote',
    ].contains(extension)) {
      throw const FormatException(
        '仅支持 Markdown、TXT、HTML、RTF、DOCX 或 .gemsnote 资源归档',
      );
    }
    final limit = extension == 'gemsnote'
        ? NoteBundle.maxArchiveBytes
        : maxBytes;
    if ((file.lengthSync() ?? 0) > limit) {
      throw StateError('文件超过允许大小：$limit 字节');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream().timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > limit) {
        throw StateError('文件超过允许大小：$limit 字节');
      }
      bytes.add(chunk);
    }
    if (extension == 'gemsnote') {
      final bundle = NoteBundle.decode(bytes.takeBytes());
      return ImportedNote(
        bundle.note.title,
        bundle.note.content,
        bundle.note.isMarkdown,
        bundle: bundle,
      );
    }
    final isRich = extension == 'rtf' || extension == 'docx';
    var content = isRich
        ? await compute(importRichDocument, (
            extension: extension,
            bytes: bytes.takeBytes(),
          ))
        : utf8.decode(bytes.takeBytes());
    if (utf8.encode(content).length > maxBytes) {
      throw const FormatException('文档内容过大或结构过于复杂');
    }
    if (content.startsWith('\ufeff')) content = content.substring(1);
    if (content.contains('\u0000')) {
      throw const FormatException('不支持二进制内容，请选择 UTF-8 文本');
    }
    var title = name
        .substring(0, dot)
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .trim();
    title = String.fromCharCodes(title.runes.take(200));
    if (title.isEmpty) title = strings.label('导入的笔记');
    return ImportedNote(
      title,
      content,
      !isRich && extension != 'html' && extension != 'htm',
      warning: isRich ? richDocumentWarning : null,
    );
  }
}
