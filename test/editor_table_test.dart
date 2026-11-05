import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/editor_table_dialog.dart';
import 'package:gemsnote/ui/visual_html_policy.dart';
import 'package:gemsnote/domain/models/conflict_copy.dart';
import 'package:html/parser.dart' as html;

void main() {
  test('table dimensions and empty cells survive HTML parsing', () {
    for (final size in [(1, 1), (3, 4), (20, 10)]) {
      final source = buildEditorTable(size.$1, size.$2);
      final fragment = html.parseFragment(source);
      expect(fragment.querySelectorAll('tr'), hasLength(size.$1));
      expect(fragment.querySelectorAll('td'), hasLength(size.$1 * size.$2));
      expect(
        fragment
            .querySelectorAll('td')
            .every((cell) => cell.innerHtml == '<br>'),
        isTrue,
      );
      expect(supportsVisualHtml(source), isTrue);
      expect(supportsVisualHtml(fragment.outerHtml), isTrue);
      expect(source, endsWith('<p><br></p>'));
    }
  });
  test('table size is bounded', () {
    for (final size in [(0, 1), (1, 0), (21, 1), (1, 11), (-1, 3)]) {
      expect(() => buildEditorTable(size.$1, size.$2), throwsArgumentError);
    }
  });
  test('basic tables accepted without broadening copy policy or allowing unsafe attributes', () {
    const source =
        '<table><caption>标题</caption><thead><tr><th>列</th></tr></thead><tbody><tr><td>正文</td></tr></tbody></table>';
    expect(supportsVisualHtml(source), isTrue);
    expect(canCopyConflictBody(source, isMarkdown: false), isFalse);
    for (final source in [
      '<table style="background:url(https://host)"><tr><td>x</td></tr></table>',
      '<table><tr><td onclick="alert(1)">x</td></tr></table>',
      '<table><tr><td colspan="11">x</td></tr></table>',
    ]) {
      expect(supportsVisualHtml(source), isFalse);
    }
  });
  testWidgets(
    'table dialog validates dimensions and inserts only on confirmation',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => const EditorTableDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '21');
      await tester.tap(find.text('插入'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('行数须为 1–20，列数须为 1–10 的整数。'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '2');
      await tester.enterText(find.byType(TextField).last, '4');
      await tester.tap(find.text('插入'));
      await tester.pumpAndSettle();
      expect(result, buildEditorTable(2, 4));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );
}
