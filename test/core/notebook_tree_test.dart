import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/notebook_tree.dart';

Notebook book(String id, String parent, String title) => Notebook(
  notebookId: id,
  parentNotebookId: parent,
  title: title,
  sequence: 0,
  usn: 1,
  numberNotes: 0,
  isDeleted: false,
);

void main() {
  test(
    'children are collapsed and siblings keep stable alphabetical order',
    () {
      final books = [
        book('b', '', 'Bravo'),
        book('c', 'a', 'Child'),
        book('a', '', 'Alpha'),
        book('d', 'c', 'Deep'),
      ];
      final tree = NotebookTree(books);
      expect(tree.visibleRows({}).map((r) => r.notebook.notebookId), [
        'a',
        'b',
      ]);
      final expanded = tree.visibleRows({'a', 'c'});
      expect(expanded.map((r) => r.notebook.notebookId), ['a', 'c', 'd', 'b']);
      expect(expanded.map((r) => r.depth), [0, 1, 2, 0]);
      expect(
        NotebookTree(books.reversed)
            .visibleRows({'a', 'c'})
            .map((r) => r.notebook.notebookId),
        ['a', 'c', 'd', 'b'],
      );
    },
  );

  test('orphans, self links and disconnected cycles remain reachable', () {
    final books = [
      book('a', 'b', 'A'),
      book('b', 'a', 'B'),
      book('c', 'missing', 'C'),
      book('d', 'd', 'D'),
    ];
    final rows = NotebookTree(books).visibleRows({'a', 'b', 'c', 'd'});
    expect(rows.map((r) => r.notebook.notebookId).toSet(), {
      'a',
      'b',
      'c',
      'd',
    });
    expect(rows.length, 4);
    expect(books[0].parentNotebookId, 'b');
    expect(books[3].parentNotebookId, 'd');
  });
}
