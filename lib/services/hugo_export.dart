import 'dart:convert';

import 'rich_document.dart';

import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../domain/models/note.dart';
import '../domain/models/notebook.dart';

String hugoMarkdown(Note note, String notebook) {
  String quote(Object value) =>
      jsonEncode(value)
          .replaceAll('\u0085', r'\u0085')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
  String date(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed == null
        ? 'null'
        : jsonEncode(parsed.toUtc().toIso8601String());
  }

  return '---\n'
      'title: ${quote(note.title)}\n'
      'date: ${date(note.createdTime)}\n'
      'lastmod: ${date(note.updatedTime)}\n'
      'tags: ${quote(note.tags)}\n'
      'categories: ${quote(notebook.isEmpty ? <String>[] : [notebook])}\n'
      '---\n\n${note.content}';
}

String exportPathName(String value) {
  var name = String.fromCharCodes(
    value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
        .trim()
        .replaceAll(RegExp(r'^\.+|[. ]+$'), '')
        .runes
        .take(70),
  );
  while (utf8.encode(name).length > 200) {
    name = String.fromCharCodes(name.runes.take(name.runes.length - 1));
  }
  if (name.isEmpty) name = 'note';
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return name;
}

/// Runs in an isolate. All input is scoped to the current account's cache.
Uint8List notebookArchive(
  ({Notebook root, List<Notebook> books, List<Note> notes}) input,
) {
  final archive = Archive();
  final visited = <String>{};
  var size = 0, count = 0;
  String unique(String title, Set<String> used, [String suffix = '']) {
    final base = exportPathName(title);
    var result = '$base$suffix', index = 2;
    while (!used.add(result.toLowerCase())) {
      result = '$base (${index++})$suffix';
    }
    return result;
  }

  void walk(Notebook book, String path) {
    if (!visited.add(book.notebookId)) throw StateError('笔记本层级异常，无法导出');
    if (visited.length > 3000 || path.split('/').length > 100) {
      throw StateError('导出内容过大或笔记本层级过深，请分批导出');
    }
    archive.addFile(ArchiveFile.directory('$path/'));
    final used = <String>{};
    final children = input.books
        .where((b) => !b.isDeleted && b.parentNotebookId == book.notebookId)
        .map((child) => (child, unique(child.title, used)))
        .toList();
    for (final note in input.notes.where(
      (n) => n.notebookId == book.notebookId && !n.isTrash && !n.isDeleted,
    )) {
      final bytes = utf8.encode(
        note.isMarkdown
            ? hugoMarkdown(note, book.title)
            : htmlToRtf(note.content, title: note.title),
      );
      size += bytes.length;
      if (size > 128 * 1024 * 1024 || ++count > 10000) {
        throw StateError('导出内容过大或笔记本层级过深，请分批导出');
      }
      archive.addFile(
        ArchiveFile(
          '$path/${unique(note.title, used, note.isMarkdown ? '.md' : '.rtf')}',
          bytes.length,
          bytes,
        ),
      );
    }
    for (final (child, name) in children) {
      walk(child, '$path/$name');
    }
  }

  walk(input.root, exportPathName(input.root.title));
  return ZipEncoder().encodeBytes(archive);
}
