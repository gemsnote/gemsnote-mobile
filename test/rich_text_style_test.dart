import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/rich_text_style.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:gemsnote/ui/visual_html_editor.dart';

void main() {
  test(
    'editor accepts bounded CSS and legacy font markup without rewriting',
    () {
      for (final source in [
        '<p style="text-align: center; color: rgb(21, 101, 192); font-size: 18pt">中</p>',
        '<span style="background-color:#fff59d;font-weight:700;font-style:italic;text-decoration:underline line-through">text</span>',
        '<font color="#f00" face="Arial" size="5"><strike>font</strike></font>',
        '<p align="right"><span style="font-family: Georgia, serif">serif</span></p>',
        '<td style="text-align:right">cell</td>',
      ]) {
        // A td must have a table context for strict HTML parsing.
        final input = source.startsWith('<td')
            ? '<table><tr>$source</tr></table>'
            : source;
        expect(supportsVisualHtml(input), isTrue, reason: input);
        expect(visualEditorDocument(input), contains('const original ='));
      }
    },
  );

  test('unsupported CSS cannot gain resource access or unbounded layout', () {
    for (final css in [
      'background:url(https://evil.test/image)',
      'color:var(--secret)',
      'color:expression(alert(1))',
      r'c\6flor:red',
      'color:red!important',
      'color:rgb(256,0,0)',
      'color:rgba(0,0,0,NaN)',
      'color:rgba(0,0,0,2)',
      'color:red;position:fixed',
      'font-family:remote',
      'font-size:1000px',
      'font-size:calc(10px + 2px)',
      'font-size:0px',
      'text-align:invalid',
      'color:/**/red',
      '--x:red',
      'font-weight:1',
    ]) {
      expect(RichTextStyle.parse(css), isNull, reason: css);
      expect(supportsVisualHtml('<p style="$css">text</p>'), isFalse);
    }
    expect(supportsVisualHtml('<font size="99">large</font>'), isFalse);
    expect(
      supportsVisualHtml('<font color="red" onmouseover="alert(1)">x</font>'),
      isFalse,
    );
    expect(
      supportsVisualHtml('<p style="color:red" onclick="alert(1)">x</p>'),
      isFalse,
    );
  });

  test('CSS parser maps bounded units, colors, fonts and decorations', () {
    final style = RichTextStyle.parse(
      'COLOR:#abc; color:rgba(10,20,30,0.5); font-size:18pt; font-family:"Times New Roman", serif; font-weight:600; font-style:oblique; text-decoration:underline line-through; text-align:right',
    )!;
    expect(style.textStyle.color, const Color.fromRGBO(10, 20, 30, 0.5));
    expect(style.textStyle.fontSize, 24);
    expect(style.textStyle.fontFamily, 'serif');
    expect(style.textStyle.fontWeight, FontWeight.w600);
    expect(style.textStyle.fontStyle, FontStyle.italic);
    expect(
      style.textStyle.decoration!.contains(TextDecoration.underline),
      isTrue,
    );
    expect(
      style.textStyle.decoration!.contains(TextDecoration.lineThrough),
      isTrue,
    );
    expect(style.alignment, TextAlign.right);
    expect(RichTextStyle.parseColor('#abc'), const Color(0xffaabbcc));
    expect(
      RichTextStyle.parse('text-decoration:none')!.textStyle.decoration,
      TextDecoration.none,
    );
  });

  testWidgets(
    'native reader renders font colors and aligned blocks without WebView',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SafeHtmlNoteBody(
              content:
                  '<div style="color:red"><p style="text-align:center;font-size:24px">Centered</p></div>'
                  '<font size="5" color="#00f">Legacy</font>'
                  '<p style="background:url(https://evil.test)">Unsafe stays text</p>',
            ),
          ),
        ),
      );
      final centered = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.textAlign == TextAlign.center,
        ),
      );
      expect(centered.textSpan!.toPlainText(), 'Centered');
      expect(centered.textSpan!.style!.fontSize, 24);
      expect(centered.textSpan!.style!.color, const Color(0xffff0000));
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(tester.takeException(), isNull);
      final root = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.textSpan?.toPlainText().contains('Legacy') == true,
        ),
      );
      final font = (root.textSpan! as TextSpan).children!
          .whereType<TextSpan>()
          .firstWhere((span) => span.toPlainText() == 'Legacy');
      expect(font.style!.fontSize, 24);
      expect(font.style!.color, const Color(0xff0000ff));
      expect(root.textSpan!.toPlainText(), contains('Unsafe stays text'));
    },
  );

  testWidgets('table cells preserve supported formatting', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SafeHtmlNoteBody(
            content: '<table><tr><td style="text-align:right;color:#1565c0;font-size:20px">Cell</td></tr></table>',
          ),
        ),
      ),
    );
    final cell = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.textSpan?.toPlainText() == 'Cell',
      ),
    );
    expect(cell.textAlign, TextAlign.right);
    expect(cell.style!.color, const Color(0xff1565c0));
    expect(cell.style!.fontSize, 20);
    expect(tester.takeException(), isNull);
  });
}
