import '../domain/models/note_bundle.dart';
import 'rich_document.dart';
import 'hugo_import.dart';

import 'package:archive/archive.dart';

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
    this.tags = const [],
    this.createdTime,
    this.updatedTime,
    this.archive,
  });
  final NoteBundle? bundle;
  final String? warning;
  final String title;
  final String content;
  final bool isMarkdown;
  final List<String> tags;
  final String? createdTime, updatedTime;
  final ImportedArchive? archive;
}

class ImportedArchive {
  const ImportedArchive(this.title, this.folders, this.notes);
  final String title;
  final List<String> folders;
  final List<({String folder, ImportedNote note})> notes;
}

ImportedArchive parseMarkdownArchive(({String name, Uint8List bytes}) source) {
  _validateMarkdownZip(source.bytes);
  final archive = ZipDecoder().decodeBytes(source.bytes, verify: true);
  if (archive.length > 5000) throw const FormatException('ZIP 文件数量超出导入限制');
  final folders = <String>{}, seen = <String>{};
  final notes = <({String folder, ImportedNote note})>[];
  var total = 0;
  void addFolder(String name) {
    final parts = name.split('/');
    for (var i = 1; i <= parts.length; i++) {
      folders.add(parts.take(i).join('/'));
    }
  }

  for (final file in archive) {
    final name = file.name.replaceFirst(RegExp(r'/$'), '');
    final parts = name.split('/');
    if (name.isEmpty ||
        RegExp(r'[\\\x00-\x1f\x7f]').hasMatch(name) ||
        name.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(name) ||
        parts.any((p) => p.isEmpty || p == '.' || p == '..') ||
        parts.length > 20 ||
        file.isSymbolicLink ||
        !seen.add(name)) {
      throw const FormatException('ZIP 中包含不安全或重复的文件路径');
    }
    if (parts.any(
      (p) => p == '__MACOSX' || p.startsWith('._') || p == '.DS_Store',
    )) {
      continue;
    }
    if (!file.isFile) {
      addFolder(name);
      continue;
    }
    if (!RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(name)) {
      continue;
    }
    total += file.size;
    if (file.size > 4 * 1024 * 1024 ||
        total > 64 * 1024 * 1024 ||
        notes.length >= 2000) {
      throw const FormatException('文档内容大小超出导入限制');
    }
    final folder = parts.take(parts.length - 1).join('/');
    if (folder.isNotEmpty) addFolder(folder);
    final markdown = parseHugoMarkdown(
      utf8.decode(file.content),
      parts.last.replaceFirst(
        RegExp(r'\.(md|markdown)$', caseSensitive: false),
        '',
      ),
    );
    notes.add((
      folder: folder,
      note: ImportedNote(
        markdown.title,
        markdown.content,
        true,
        tags: markdown.tags,
        createdTime: markdown.createdTime,
        updatedTime: markdown.updatedTime,
      ),
    ));
  }
  if (notes.isEmpty || folders.length > 1000) {
    throw const FormatException('ZIP 中没有可导入的文档或目录过多');
  }
  final sorted = folders.toList()
    ..sort((a, b) {
      final depth = a.split('/').length.compareTo(b.split('/').length);
      return depth != 0 ? depth : a.compareTo(b);
    });
  return ImportedArchive(
    source.name.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), ''),
    sorted,
    notes,
  );
}

// Check directory sizes, paths and local headers before the decoder can read
// any payload (including a malicious symlink target or a decompression bomb).
void _validateMarkdownZip(Uint8List bytes) {
  Never invalid() => throw const FormatException('ZIP 中包含不安全或重复的文件路径');
  if (bytes.length < 22 || bytes.length > NoteImporter.maxBytes) invalid();
  final data = ByteData.sublistView(bytes);
  int u16(int n) => data.getUint16(n, Endian.little);
  int u32(int n) => data.getUint32(n, Endian.little);
  var end = bytes.length - 22;
  final min = bytes.length > 65557 ? bytes.length - 65557 : 0;
  while (end >= min &&
      (u32(end) != 0x06054b50 || end + 22 + u16(end + 20) != bytes.length)) {
    end--;
  }
  if (end < min) invalid();
  final count = u16(end + 10), offset = u32(end + 16);
  if (u16(end + 4) != 0 ||
      u16(end + 6) != 0 ||
      u16(end + 8) != count ||
      count > 5000 ||
      offset + u32(end + 12) != end) {
    invalid();
  }
  var pos = offset, total = 0, notes = 0;
  final seen = <String>{};
  for (var i = 0; i < count; i++) {
    if (pos + 46 > end || u32(pos) != 0x02014b50) invalid();
    final flags = u16(pos + 8),
        method = u16(pos + 10),
        size = u32(pos + 24),
        compressed = u32(pos + 20),
        nameSize = u16(pos + 28),
        local = u32(pos + 42);
    final next = pos + 46 + nameSize + u16(pos + 30) + u16(pos + 32);
    if (next > end ||
        flags & 1 != 0 ||
        u16(pos + 34) != 0 ||
        (u32(pos + 38) >> 16 & 0xf000) == 0xa000) {
      invalid();
    }
    final name = utf8
        .decode(bytes.sublist(pos + 46, pos + 46 + nameSize))
        .replaceFirst(RegExp(r'/$'), '');
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.contains('\\') ||
        RegExp(r'^[a-zA-Z]:|[\x00-\x1f\x7f]').hasMatch(name) ||
        name.split('/').any((p) => p.isEmpty || p == '.' || p == '..') ||
        name.split('/').length > 20 ||
        !seen.add(name)) {
      invalid();
    }
    if (local + 30 > offset ||
        u32(local) != 0x04034b50 ||
        u16(local + 6) != flags ||
        u16(local + 8) != method) {
      invalid();
    }
    if (local + 30 + u16(local + 26) + u16(local + 28) + compressed > offset) {
      invalid();
    }
    if (RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(name)) {
      total += size;
      if ((method != 0 && method != 8) ||
          size > 4 * 1024 * 1024 ||
          total > 64 * 1024 * 1024 ||
          ++notes > 2000) {
        throw const FormatException('文档内容大小超出导入限制');
      }
    }
    pos = next;
  }
  if (pos != end) invalid();
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
          : [
              'md',
              'markdown',
              'txt',
              'html',
              'htm',
              'rtf',
              'docx',
              'gemsnote',
              'zip',
            ],
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
      'zip',
    ].contains(extension)) {
      throw const FormatException(
        '仅支持 Markdown、TXT、HTML、RTF、DOCX、ZIP 或 .gemsnote 资源归档',
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
    if (extension == 'zip') {
      final archive = await compute(parseMarkdownArchive, (
        name: name,
        bytes: bytes.takeBytes(),
      ));
      return ImportedNote(archive.title, '', true, archive: archive);
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
    if (extension == 'md' || extension == 'markdown') {
      final markdown = parseHugoMarkdown(content, title);
      return ImportedNote(
        markdown.title,
        markdown.content,
        true,
        tags: markdown.tags,
        createdTime: markdown.createdTime,
        updatedTime: markdown.updatedTime,
      );
    }
    return ImportedNote(
      title,
      content,
      !isRich && extension != 'html' && extension != 'htm',
      warning: isRich ? richDocumentWarning : null,
    );
  }
}
