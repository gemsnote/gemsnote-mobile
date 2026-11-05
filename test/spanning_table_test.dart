import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:gemsnote/ui/spanning_table.dart';
import 'package:html/parser.dart' as html;

void main() {
  HtmlTableGrid? parse(String source) =>
      HtmlTableGrid.parse(html.parseFragment(source).querySelector('table')!);
  test('grid accounts for rowspan origins, gaps and fully covered rows', () {
    final grid = parse(
      '<table><tr><td rowspan="2">A</td><td>B</td></tr><tr><td>C</td></tr><tr><td colspan="2" rowspan="2">D</td></tr><tr></tr></table>',
    )!;
    expect(grid.rows, 4);
    expect(grid.columns, 2);
    expect(
      grid.cells.map(
        (cell) => (cell.row, cell.column, cell.rows, cell.columns),
      ),
      [(0, 0, 2, 1), (0, 1, 1, 1), (1, 1, 1, 1), (2, 0, 2, 2)],
    );
    expect(
      parse(
        '<table><tr><td colspan="2">A</td></tr><tr><td>B</td></tr></table>',
      )!.cells.last.element,
      isNull,
    );
  });
  test('invalid overlapping and unbounded spans fall back instead of allocating huge grids', () {
    for (final source in [
      '<table><tr><td rowspan="9999999">A</td></tr></table>',
      '<table><tr><td colspan="0">A</td></tr></table>',
      '<table><tr><td colspan="-1">A</td></tr></table>',
      '<table><tr><td colspan="21">A</td></tr></table>',
      '<table><tr><td rowspan="2">A</td></tr></table>',
      '<table><tr><td>A</td><td rowspan="2">B</td></tr><tr><td colspan="2">C</td></tr></table>',
      '<table><thead><tr><th rowspan="2">A</th></tr></thead><tbody><tr></tr></tbody></table>',
    ]) {
      expect(parse(source), isNull);
    }
  });
  testWidgets(
    'merged native cells have correct bounds and long content expands rows',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: SafeHtmlNoteBody(
                  content:
                      '<table><caption>Grid</caption><tr><td rowspan="2">Tall ${List.filled(80, 'word').join(' ')}</td><td>B</td></tr><tr><td>C</td></tr><tr><td colspan="2">Wide</td></tr></table>',
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(SpanningTable), findsOneWidget);
      expect(find.text('Grid', findRichText: true), findsOneWidget);
      final grid = tester.renderObject<RenderBox>(find.byType(SpanningTable));
      final first = tester.renderObject<RenderBox>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.child is Text &&
              ((w.child as Text).textSpan?.toPlainText().startsWith('Tall') ??
                  false),
        ),
      );
      expect(first.size.height, greaterThan(80));
      final wide = tester.renderObject<RenderBox>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.child is Text &&
              (w.child as Text).textSpan?.toPlainText() == 'Wide',
        ),
      );
      expect(wide.size.width, grid.size.width);
      expect(grid.size.height, greaterThan(first.size.height));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'merged cells preserve script/media policy and horizontal scrolling',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: SafeHtmlNoteBody(
                content: '<table><tr><td colspan="3">Visible<script>secret()</script><img src="https://example.test/image"><a href="https://example.test/">link</a></td></tr></table>',
              ),
            ),
          ),
        ),
      );
      expect(find.byType(SpanningTable), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .join();
      expect(text, contains('Visible'));
      expect(text, isNot(contains('secret()')));
      expect(text, contains('媒体尚未缓存'));
      await tester.drag(
        find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
