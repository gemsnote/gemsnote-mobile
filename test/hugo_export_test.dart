import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/services/hugo_export.dart';

void main() {
  final note = Note.fromJson({
    'NoteId': 'n',
    'NotebookId': 'root',
    'Title': 'a: "b"\nnext',
    'Tags': ['yes', 'a: b'],
    'CreatedTime': '2020-01-01T12:00:00+08:00',
    'UpdatedTime': '2021-01-01T00:00:00Z',
    'IsMarkdown': true,
    'Content': '# Body\r\n',
  });
  Notebook book(String id, String title, [String parent = '']) =>
      Notebook.fromJson({
        'NotebookId': id,
        'Title': title,
        'ParentNotebookId': parent,
      });
  test('Hugo metadata is escaped and original body is preserved', () {
    final result = hugoMarkdown(note, 'Book');
    expect(result, contains('title: "a: \\"b\\"\\nnext"'));
    expect(result, contains('date: "2020-01-01T04:00:00.000Z"'));
    expect(result, contains('lastmod: "2021-01-01T00:00:00.000Z"'));
    expect(result, contains('tags: ["yes","a: b"]'));
    expect(result, contains('categories: ["Book"]'));
    expect(result, endsWith(note.content));
  });
  test(
    'ZIP keeps nesting and empty books and avoids overwriting duplicates',
    () {
      final root = book('root', '../Book');
      final bytes = notebookArchive((
        root: root,
        books: [
          root,
          book('child', 'Child', 'root'),
          book('empty', 'child', 'root'),
        ],
        notes: [
          note.copyWith(title: 'Same'),
          note.copyWith(noteId: 'n2', title: 'Same'),
          note.copyWith(noteId: 'n3', notebookId: 'child'),
          note.copyWith(noteId: 'trash', isTrash: true),
        ],
      ));
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(
        archive.files.map((f) => f.name),
        containsAll([
          '_Book/',
          '_Book/Same.md',
          '_Book/Same (2).md',
          '_Book/Child/',
          '_Book/child (2)/',
        ]),
      );
      expect(archive.files.where((f) => f.isFile).length, 3);
      expect(
        utf8.decode(
          archive.files.firstWhere((f) => f.name == '_Book/Same.md').content,
        ),
        contains('categories: ["../Book"]'),
      );
      expect(exportPathName('CON'), '_CON');
    },
  );
}
