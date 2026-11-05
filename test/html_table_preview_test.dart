import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';

void main() {
  Widget preview(String source) => MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 320, child: SafeHtmlNoteBody(content: source)),
    ),
  );

  testWidgets(
    'native grid retains caption headers and uneven rows on small screens',
    (tester) async {
      await tester.pumpWidget(
        preview(
          '<p>前文</p><table><caption>统计</caption>'
          '<tr><th>名称</th><th>数量</th><th>备注</th></tr>'
          '<tr><td><b>笔记</b></td><td>12</td></tr></table><p>后文</p>',
        ),
      );
      expect(find.byType(Table), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.text('统计', findRichText: true), findsOneWidget);
      expect(find.text('笔记', findRichText: true), findsOneWidget);
      final table = tester.widget<Table>(find.byType(Table));
      expect(table.children, hasLength(2));
      expect(table.children.last.children, hasLength(3));
      final horizontal = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsOneWidget);
      await tester.drag(horizontal, const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('complex and oversized tables fall back without losing text', (
    tester,
  ) async {
    for (final source in [
      '<table><tr><td colspan="21">保留文字</td></tr></table>',
      '<table><tr><td><table><tr><td>保留文字</td></tr></table></td></tr></table>',
      '<table>${List.filled(101, '<tr><td>保留文字</td></tr>').join()}</table>',
    ]) {
      await tester.pumpWidget(preview(source));
      expect(find.byType(Table), findsNothing);
      final text = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText();
      expect(text, contains('保留文字'));
      expect(text, contains('复杂或大型表格按文字显示'));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('table content uses the same safe media and script policy', (
    tester,
  ) async {
    await tester.pumpWidget(
      preview(
        '<table><tr><td>可见<script>secret()</script>'
        '<img src="https://example.com/private" alt="示例">'
        '<a href="https://example.com">链接</a></td></tr></table>',
      ),
    );
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join();
    expect(texts, contains('可见'));
    expect(texts, contains('媒体尚未缓存'));
    expect(texts, contains('https://example.com'));
    expect(texts, isNot(contains('secret()')));
  });
}
