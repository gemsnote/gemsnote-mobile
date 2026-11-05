import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_editor_page.dart';

void main() {
  testWidgets('heading menu changes level and restores body with autosave', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorPage(
          note: Note.fromJson({
            'NoteId': 'n',
            'Title': 'Title',
            'Content': '# Hello\nAfter',
            'IsMarkdown': true,
          }),
          saveText: (_, content) async => saved.add(content),
        ),
      ),
    );
    final body = tester
        .widget<TextField>(find.byType(TextField).last)
        .controller!;
    body.selection = const TextSelection.collapsed(offset: 4);
    Future<void> choose(String label) async {
      await tester.ensureVisible(find.byTooltip('标题'));
      await tester.tap(find.byTooltip('标题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
    }

    await choose('6 级标题');
    expect(body.text, '###### Hello\nAfter');
    expect(saved.last, body.text);
    await choose('正文');
    expect(body.text, 'Hello\nAfter');
    expect(saved.last, body.text);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('format selected text, preview and autosave the original', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorPage(
          note: Note.fromJson({
            'NoteId': 'n',
            'Title': 'Title',
            'Content': 'Hello world',
            'IsMarkdown': true,
          }),
          saveText: (_, content) async {
            saved.add(content);
          },
        ),
      ),
    );
    final editor = tester.widget<TextField>(find.byType(TextField).last);
    editor.controller!.selection = const TextSelection(
      baseOffset: 6,
      extentOffset: 11,
    );
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(editor.controller!.text, 'Hello **world**');
    expect(
      editor.controller!.selection.textInside(editor.controller!.text),
      'world',
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(saved, ['Hello **world**']);
    await tester.tap(find.byTooltip('预览 Markdown'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Markdown>(find.byType(Markdown)).data,
      'Hello **world**',
    );
    expect(find.byTooltip('加粗'), findsNothing);
    await tester.tap(find.byTooltip('继续编辑'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'Hello **world**',
    );
    expect(saved, ['Hello **world**']);
  });

  testWidgets(
    'preview flushes pending edits and switching unchanged does not save',
    (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditorPage(
            note: Note.fromJson({
              'Title': 'Title',
              'Content': 'original',
              'IsMarkdown': true,
            }),
            saveText: (_, content) async {
              saved.add(content);
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('预览 Markdown'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      await tester.tap(find.byTooltip('继续编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '# New draft');
      await tester.tap(find.byTooltip('预览 Markdown'));
      await tester.pumpAndSettle();
      expect(saved, ['# New draft']);
      expect(find.text('New draft'), findsOneWidget);
    },
  );

  testWidgets(
    'rich-text editor has a separate HTML preview and no Markdown controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditorPage(
            note: Note.fromJson({
              'Title': 'Title',
              'Content': '<p>Body</p>',
              'IsMarkdown': false,
            }),
            saveText: (_, _) async {},
          ),
        ),
      );
      expect(find.byTooltip('预览 Markdown'), findsNothing);
      expect(find.byTooltip('预览富文本'), findsOneWidget);
      expect(find.byTooltip('加粗'), findsNothing);
      expect(find.text('<p>Body</p>'), findsOneWidget);
    },
  );
}
