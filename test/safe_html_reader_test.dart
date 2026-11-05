import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_reader_page.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  Widget body(String html) => MaterialApp(
    home: Scaffold(body: SafeHtmlNoteBody(content: html)),
  );
  String text(WidgetTester tester) => tester
      .widget<SelectableText>(find.byType(SelectableText))
      .textSpan!
      .toPlainText();

  testWidgets(
    'native preview retains basic structure, entities and preformatted text',
    (tester) async {
      await tester.pumpWidget(
        body(
          '<h1>Heading</h1><p><b>Bold</b> &amp; <em>Italic</em></p><ol><li>one</li><li>two</li></ol><ul><li>bullet</li></ul><pre> a\n  b</pre><table><tr><td>A</td><td>B</td></tr></table>',
        ),
      );
      final root =
          tester
                  .widget<Text>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is Text &&
                          widget.textSpan?.toPlainText().contains('Heading') ==
                              true,
                    ),
                  )
                  .textSpan!
              as TextSpan;
      final rendered = root.toPlainText();
      for (final part in [
        'Heading',
        'Bold & Italic',
        '1. one',
        '2. two',
        '• bullet',
        ' a\n  b',
      ]) {
        expect(rendered, contains(part));
      }
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('A', findRichText: true), findsOneWidget);
      expect(find.text('B', findRichText: true), findsOneWidget);
      final heading = root.children!.whereType<TextSpan>().firstWhere(
        (span) => span.toPlainText() == 'Heading',
      );
      expect(heading.style!.fontWeight, FontWeight.bold);
      expect(find.byType(WebViewWidget), findsNothing);
    },
  );

  testWidgets(
    'active content, styles and media never create executable widgets',
    (tester) async {
      await tester.pumpWidget(
        body(
          '<style>@import "https://bad.test";</style><script>SECRET_SCRIPT</script><iframe srcdoc="bad">SECRET_FRAME</iframe><svg><text>SECRET_SVG</text></svg><form>SECRET_FORM</form><p style="background:url(https://bad.test)">visible</p><img src="file:///private" alt="photo" onerror="bad()"><video src="https://bad.test/v"></video><a href="javascript:bad()">link</a>',
        ),
      );
      final rendered = text(tester);
      expect(rendered, contains('visible'));
      expect(rendered, isNot(contains('SECRET')));
      expect(rendered, isNot(contains('@import')));
      expect(rendered, contains('[媒体尚未缓存：photo]'));
      expect(rendered, contains('link (javascript:bad())'));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('malformed and deeply nested HTML is bounded', (tester) async {
    await tester.pumpWidget(body('${List.filled(100, '<div>').join()}<b>deep'));
    expect(text(tester), contains('嵌套内容过深'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared rich text toggles preview and copies exact HTML without edit actions',
    (tester) async {
      const source = '<p><strong>Example</strong></p>';
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: Note.fromJson({
              'NoteId': 'n',
              'Title': 'Title',
              'Content': source,
              'IsMarkdown': false,
            }),
            readOnly: true,
            safeHtmlPreview: true,
          ),
        ),
      );
      expect(find.byType(SafeHtmlNoteBody), findsOneWidget);
      expect(find.byTooltip('编辑'), findsNothing);
      await tester.tap(find.byTooltip('查看原文'));
      await tester.pumpAndSettle();
      expect(find.text(source), findsOneWidget);
      await tester.tap(find.byTooltip('复制 HTML 原文'));
      await tester.pumpAndSettle();
      expect(copied, source);
      await tester.tap(find.byTooltip('查看预览'));
      await tester.pumpAndSettle();
      expect(find.byType(SafeHtmlNoteBody), findsOneWidget);
    },
  );
}
