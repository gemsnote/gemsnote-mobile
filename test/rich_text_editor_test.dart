import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_editor_page.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  const source =
      '<p data-custom="keep"><b>Original</b>&nbsp;</p><img src="https://example.test/private"><script>secret()</script>';
  Widget editor(Future<void> Function(String, String) save) => MaterialApp(
    home: NoteEditorPage(
      note: Note.fromJson({
        'NoteId': 'n',
        'Title': 'Title',
        'Content': source,
        'IsMarkdown': false,
      }),
      saveText: save,
    ),
  );

  testWidgets(
    'unsupported visual editing preserves original without launching WebView',
    (tester) async {
      final saves = <String>[];
      await tester.pumpWidget(editor((_, text) async => saves.add(text)));
      await tester.tap(find.byTooltip('可视化编辑'));
      await tester.pump();
      expect(
        find.text('此笔记包含图片、不支持的链接或复杂 HTML，请继续编辑原文，避免丢失内容。'),
        findsOneWidget,
      );
      expect(find.byType(WebViewWidget), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        source,
      );
      expect(saves, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'HTML preview does not rewrite or save unchanged source and preserves selection',
    (tester) async {
      final saves = <String>[];
      await tester.pumpWidget(editor((_, text) async => saves.add(text)));
      final controller = tester
          .widget<TextField>(find.byType(TextField).last)
          .controller!;
      controller.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 12,
      );
      await tester.tap(find.byTooltip('预览富文本'));
      await tester.pumpAndSettle();
      expect(find.byType(SafeHtmlNoteBody), findsOneWidget);
      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.byType(Image), findsNothing);
      final preview = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText();
      expect(preview, contains('Original'));
      expect(preview, isNot(contains('secret()')));
      expect(saves, isEmpty);
      await tester.tap(find.byTooltip('继续编辑'));
      await tester.pumpAndSettle();
      expect(controller.text, source);
      expect(
        controller.selection,
        const TextSelection(baseOffset: 3, extentOffset: 12),
      );
      expect(saves, isEmpty);
    },
  );

  testWidgets(
    'preview flushes unsaved HTML exactly once, including unsupported markup',
    (tester) async {
      final saves = <String>[];
      await tester.pumpWidget(editor((_, text) async => saves.add(text)));
      const draft =
          '<custom data-x="value"><p>New &amp; draft</p></custom><iframe src="https://example.test"></iframe>';
      await tester.enterText(find.byType(TextField).last, draft);
      await tester.tap(find.byTooltip('预览富文本'));
      await tester.pumpAndSettle();
      expect(saves, [draft]);
      expect(
        tester.widget<SafeHtmlNoteBody>(find.byType(SafeHtmlNoteBody)).content,
        draft,
      );
      await tester.tap(find.byTooltip('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        draft,
      );
      expect(saves, [draft]);
    },
  );

  testWidgets(
    'failed preview flush shows error, retains draft and supports retry',
    (tester) async {
      var fail = true;
      final saves = <String>[];
      await tester.pumpWidget(
        editor((_, text) async {
          if (fail) throw StateError('disk full');
          saves.add(text);
        }),
      );
      await tester.enterText(find.byType(TextField).last, '<p>Draft</p>');
      await tester.tap(find.byTooltip('预览富文本'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存到本地失败'), findsOneWidget);
      expect(
        tester.widget<SafeHtmlNoteBody>(find.byType(SafeHtmlNoteBody)).content,
        '<p>Draft</p>',
      );
      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(saves, ['<p>Draft</p>']);
      expect(find.textContaining('保存到本地失败'), findsNothing);
    },
  );
}
