import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/note_tags_dialog.dart';

void main() {
  testWidgets(
    'existing tag suggestions filter, exclude selected tags and save chips',
    (tester) async {
      List<String>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteTagsDialog(
              tags: const ['one'],
              loadSuggestions: () async => {
                'one': 5,
                'alpha': 3,
                'Alpine': 2,
                'rare': 1,
              },
              onSave: (tags) async {
                saved = tags;
                throw StateError('keep dialog');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ActionChip), findsNWidgets(3));
      await tester.enterText(find.byType(TextField), 'AL');
      await tester.pump();
      expect(find.byType(ActionChip), findsNWidgets(2));
      await tester.tap(find.widgetWithText(ActionChip, 'alpha'));
      await tester.pump();
      expect(find.widgetWithText(InputChip, 'alpha'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'alpha'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved, ['one', 'alpha']);
    },
  );

  testWidgets(
    'suggestion failure is retryable and IME composition is not committed',
    (tester) async {
      var fail = true;
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteTagsDialog(
              tags: const [],
              loadSuggestions: () async {
                if (fail) throw StateError('read failed');
                return {'中文': 1};
              },
              onSave: (_) async {
                saved = true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('读取已有标签失败，点击重试'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('读取已有标签失败，点击重试'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, '中文'), findsOneWidget);
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.value = const TextEditingValue(
        text: '中文',
        composing: TextRange(start: 0, end: 2),
      );
      await tester.tap(find.byTooltip('添加标签'));
      await tester.pump();
      expect(find.byType(InputChip), findsNothing);
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(saved, isFalse);
    },
  );

  testWidgets(
    'pending input is included on save, failure keeps dialog and supports retry',
    (tester) async {
      List<String>? saved;
      var fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => NoteTagsDialog(
                    tags: const ['one'],
                    onSave: (tags) async {
                      saved = tags;
                      if (fail) throw StateError('offline');
                    },
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' two ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved, ['one', 'two']);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.byType(NoteTagsDialog), findsOneWidget);
      fail = false;
      await tester.enterText(find.byType(TextField), 'two');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved, ['one', 'two']);
      expect(find.byType(NoteTagsDialog), findsNothing);
    },
  );
}
