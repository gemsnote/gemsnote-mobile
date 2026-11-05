import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/markdown_editing.dart';
import 'package:gemsnote/ui/note_editor_page.dart';

void main() {
  test(
    'numbered lines honor reverse selections and exclusive trailing newline',
    () {
      const value = TextEditingValue(
        text: 'a\nb\nc',
        selection: TextSelection(baseOffset: 4, extentOffset: 0),
      );
      final result = numberMarkdownLines(value);
      expect(result.text, '1. a\n2. b\nc');
      expect(result.selection.textInside(result.text), '1. a\n2. b');
      expect(
        numberMarkdownLines(const TextEditingValue(text: 'x')).text,
        '1. x',
      );
    },
  );
  test('links escape labels and protect special destination characters', () {
    const value = TextEditingValue(
      text: 'a[b]*',
      selection: TextSelection(baseOffset: 0, extentOffset: 5),
    );
    final result = insertMarkdownLink(value, 'https://example.com/a(b)?q=<x>');
    expect(result.text, r'[a\[b\]\*](<https://example.com/a(b)?q=%3Cx%3E>)');
    expect(result.selection.extentOffset, result.text.length);
    expect(
      () => insertMarkdownLink(value, 'javascript:alert(1)'),
      throwsArgumentError,
    );
    expect(
      insertMarkdownLink(const TextEditingValue(), 'https://example.com').text,
      '[https://example.com](<https://example.com>)',
    );
  });
  test('code fences cannot be terminated by selected backticks and keep surrounding prose', () {
    const value = TextEditingValue(
      text: 'before```x```after',
      selection: TextSelection(baseOffset: 6, extentOffset: 13),
    );
    final result = fenceMarkdownCode(value);
    expect(result.text, 'before\n\n````\n```x```\n````\n\nafter');
    expect(result.selection.textInside(result.text), '```x```');
    final empty = fenceMarkdownCode(const TextEditingValue());
    expect(empty.text, '```\n\n```\n');
    expect(empty.selection.baseOffset, 4);
  });
  testWidgets(
    'Markdown link keeps body selection across dialog and autosaves; cancel does not write',
    (tester) async {
      final saves = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditorPage(
            note: Note.fromJson({
              'NoteId': 'n',
              'Title': 'Title',
              'Content': 'hello world',
              'IsMarkdown': true,
            }),
            saveText: (_, content) async => saves.add(content),
          ),
        ),
      );
      final body = tester
          .widget<TextField>(find.byType(TextField).last)
          .controller!;
      body.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
      await tester.ensureVisible(find.byTooltip('插入链接'));
      await tester.tap(find.byTooltip('插入链接'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'https://example.com',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(body.text, 'hello [world](<https://example.com>)');
      expect(saves, [body.text]);
      await tester.ensureVisible(find.byTooltip('插入链接'));
      await tester.tap(find.byTooltip('插入链接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(saves, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
