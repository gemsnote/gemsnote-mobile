import '../domain/models/note_bundle.dart';
import '../domain/models/notebook.dart';
import 'hugo_export.dart';
import 'rich_document.dart';

import 'package:flutter/foundation.dart' show compute;

import 'dart:ui' show Locale;

import '../l10n/app_strings.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../domain/models/note.dart';

typedef SaveNoteFile = Future<Uri?> Function({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
});

class NoteExporter {
  NoteExporter({
    SaveNoteFile? save,
    this.strings = const AppStrings(Locale('zh')),
  }) : _save =
           save ??
           (({required fileName, required bytes, required mimeType}) =>
               _saveSystem(
                 fileName: fileName,
                 bytes: bytes,
                 mimeType: mimeType,
                 dialogTitle: strings.label('导出笔记'),
               ));
  final AppStrings strings;
  final SaveNoteFile _save;

  static Future<Uri?> _saveSystem({
    required String dialogTitle,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) => FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
    dialogTitle: dialogTitle,
  );

  static String fileName(Note note, {String fallback = '未命名笔记'}) {
    final extension = note.isMarkdown ? '.md' : '.rtf';
    return safeFileName(note.title, extension, fallback: fallback);
  }

  static String safeFileName(
    String name,
    String extension, {
    required String fallback,
  }) {
    var title = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_')
        .trim();
    title = title.replaceAll(RegExp(r'^\.+|[. ]+$'), '');
    if (title.toLowerCase().endsWith(extension)) {
      title = title.substring(0, title.length - extension.length);
    }
    // Bound UTF-8 bytes as well as characters: emoji can consume four bytes.
    final safeRunes = <int>[];
    var byteLength = 0;
    for (final rune in title.runes.take(80)) {
      final size = utf8.encode(String.fromCharCode(rune)).length;
      if (byteLength + size > 200) break;
      safeRunes.add(rune);
      byteLength += size;
    }
    title = String.fromCharCodes(safeRunes).trim();
    if (title.isEmpty) title = fallback;
    return '$title$extension';
  }

  Future<bool> exportBundle(NoteBundle bundle) async =>
      await _save(
        fileName: safeFileName(
          bundle.note.title,
          '.gemsnote',
          fallback: strings.label('未命名笔记'),
        ),
        bytes: bundle.encode(),
        mimeType: 'application/json',
      ) !=
      null;

  Future<bool> exportNotebook(
    Notebook root,
    List<Notebook> books,
    List<Note> notes,
  ) async {
    final bytes = await compute(notebookArchive, (
      root: root,
      books: books,
      notes: notes,
    ));
    return await _save(
          fileName: '${exportPathName(root.title)}.zip',
          bytes: bytes,
          mimeType: 'application/zip',
        ) !=
        null;
  }

  /// Markdown exports use Hugo metadata and never fetch remote media.
  Future<bool> export(Note note, {String notebook = ''}) async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        note.isMarkdown
            ? hugoMarkdown(note, notebook)
            : htmlToRtf(note.content, title: note.title),
      ),
    );
    if (bytes.length > 32 * 1024 * 1024) {
      throw StateError('笔记原文超过 32 MiB，暂不支持导出');
    }
    return await _save(
          fileName: fileName(note, fallback: strings.label('未命名笔记')),
          bytes: bytes,
          mimeType: note.isMarkdown ? 'text/markdown' : 'application/rtf',
        ) !=
        null;
  }
}
