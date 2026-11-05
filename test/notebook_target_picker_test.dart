import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/notebook_tree.dart';
import 'package:gemsnote/ui/notebook_target_picker.dart';

void main() {
  Notebook book(String id, String title, [String parent = '']) =>
      Notebook.fromJson({
        'NotebookId': id,
        'Title': title,
        'ParentNotebookId': parent,
      });
  final books = [
    book('a', 'Parent'),
    book('b', 'Child', 'a'),
    book('c', 'Grandchild', 'b'),
    book('d', 'Other'),
  ];
  testWidgets(
    'children collapse by default; expansion does not select; search preserves ancestors',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotebookTargetPicker(
              notebooks: books,
              onSelected: (id) => selected = id,
            ),
          ),
        ),
      );
      expect(find.text('Child'), findsNothing);
      await tester.tap(find.byTooltip('展开 Parent'));
      await tester.pump();
      expect(find.text('Child'), findsOneWidget);
      expect(selected, isNull);
      await tester.enterText(find.byType(TextField), 'grand');
      await tester.pump();
      expect(find.text('Parent'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Grandchild'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'Grandchild'));
      expect(selected, 'c');
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump();
      expect(find.text('没有匹配的笔记本'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Grandchild'), findsNothing);
    },
  );
  testWidgets(
    'root selection and disabled cycle targets do not change source IDs',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotebookTargetPicker(
              notebooks: books,
              allowRoot: true,
              canSelect: (id) => canMoveNotebook(books, 'a', id),
              onSelected: (id) => selected = id,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Parent'));
      expect(selected, isNull);
      await tester.enterText(find.byType(TextField), 'Grandchild');
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, 'Grandchild'));
      expect(selected, isNull);
      await tester.tap(find.text('根目录'));
      expect(selected, '');
    },
  );
  testWidgets('busy picker disables search, expansion and selection', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotebookTargetPicker(
            notebooks: books,
            enabled: false,
            onSelected: (_) => calls++,
          ),
        ),
      ),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.text('Parent'));
    await tester.tap(find.byTooltip('展开 Parent'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('Child'), findsNothing);
  });
}
