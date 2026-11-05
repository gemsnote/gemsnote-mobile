import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_editor_page.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    List<(String, String)> saved, {
    bool markdown = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorPage(
          note: Note.fromJson({
            'Title': 'Title',
            'Content': 'original',
            'IsMarkdown': markdown,
          }),
          saveText: (title, body) async => saved.add((title, body)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> settleEdit(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  bool enabled(WidgetTester tester, String label) =>
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == label,
            ),
          )
          .onPressed !=
      null;

  for (final markdown in [true, false]) {
    testWidgets(
      '${markdown ? "Markdown" : "HTML"} undo/redo persists source and survives preview',
      (tester) async {
        final saved = <(String, String)>[];
        await open(tester, saved, markdown: markdown);
        expect(enabled(tester, '撤销'), isFalse);
        expect(enabled(tester, '重做'), isFalse);
        await tester.enterText(find.byType(TextField).last, 'changed');
        await settleEdit(tester);
        expect(saved.last.$2, 'changed');
        await tester.tap(find.byTooltip(markdown ? '预览 Markdown' : '预览富文本'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('继续编辑'));
        await tester.pumpAndSettle();
        expect(enabled(tester, '撤销'), isTrue);
        await tester.tap(find.byTooltip('撤销'));
        await settleEdit(tester);
        expect(saved.last.$2, 'original');
        expect(enabled(tester, '重做'), isTrue);
        await tester.tap(find.byTooltip('重做'));
        await settleEdit(tester);
        expect(saved.last.$2, 'changed');
      },
    );
  }
  testWidgets('undo affects last focused field; a new edit discards redo', (
    tester,
  ) async {
    final saved = <(String, String)>[];
    await open(tester, saved);
    await tester.enterText(find.byType(TextField).last, 'body edit');
    await settleEdit(tester);
    await tester.enterText(find.byType(TextField).first, 'title edit');
    await settleEdit(tester);
    await tester.tap(find.byTooltip('撤销'));
    await settleEdit(tester);
    expect(saved.last, ('Title', 'body edit'));
    await tester.enterText(find.byType(TextField).first, 'different title');
    await settleEdit(tester);
    expect(enabled(tester, '重做'), isFalse);
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await tester.tap(find.byTooltip('撤销'));
    await settleEdit(tester);
    expect(saved.last, ('different title', 'original'));
  });
  testWidgets('format tools participate in body history', (tester) async {
    final saved = <(String, String)>[];
    await open(tester, saved);
    final body = tester
        .widget<TextField>(find.byType(TextField).last)
        .controller!;
    body.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
    await tester.tap(find.byTooltip('加粗'));
    await settleEdit(tester);
    expect(body.text, '**original**');
    await tester.tap(find.byTooltip('撤销'));
    await settleEdit(tester);
    expect(body.text, 'original');
    await tester.tap(find.byTooltip('重做'));
    await settleEdit(tester);
    expect(body.text, '**original**');
  });
}
