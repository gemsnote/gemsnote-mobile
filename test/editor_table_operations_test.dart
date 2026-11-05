import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/editor_table_dialog.dart';
import 'package:gemsnote/ui/editor_table_operations.dart';
import 'package:gemsnote/ui/visual_html_policy.dart';
import 'package:html/parser.dart' as html;

void main() {
  const source =
      '<table><caption>标题</caption><thead><tr><th>H1</th><th>H2</th></tr></thead>'
      '<tbody><tr><td><b>A</b></td><td>B</td></tr><tr><td>C</td><td>D</td></tr></tbody></table>';
  test('insert row preserves sections caption formatting and other cells', () {
    final result = changeEditorTable(source, 1, 0, TableOperation.addRow);
    final table = html.parseFragment(result);
    expect(table.querySelectorAll('tr'), hasLength(4));
    expect(table.querySelectorAll('thead tr'), hasLength(1));
    expect(table.querySelectorAll('tbody tr'), hasLength(3));
    expect(table.querySelectorAll('tr')[2].text, '');
    expect(table.querySelector('caption')!.text, '标题');
    expect(table.querySelector('b')!.text, 'A');
    expect(supportsVisualHtml(result), isTrue);
  });
  test('column insertion is applied to header and all body rows', () {
    final result = html.parseFragment(
      changeEditorTable(source, 1, 0, TableOperation.addColumn),
    );
    for (final row in result.querySelectorAll('tr')) {
      expect(row.children, hasLength(3));
      expect(row.children[1].innerHtml, '<br>');
    }
    expect(result.querySelectorAll('tr').first.children[1].localName, 'th');
    expect(result.querySelectorAll('tr')[1].children[2].text, 'B');
  });
  test('remove row and column only removes selected content', () {
    final rowResult = html.parseFragment(
      changeEditorTable(source, 1, 0, TableOperation.removeRow),
    );
    expect(rowResult.querySelectorAll('tr'), hasLength(2));
    expect(rowResult.querySelectorAll('tr').last.text, 'CD');
    final columnResult = html.parseFragment(
      changeEditorTable(source, 1, 1, TableOperation.removeColumn),
    );
    expect(
      columnResult.querySelectorAll('tr').map((row) => row.text).toList(),
      ['H1', 'A', 'C'],
    );
  });
  test('reject last row or column removal and growth beyond limits', () {
    expect(
      () => changeEditorTable(
        '<table><tr><td>x</td></tr></table>',
        0,
        0,
        TableOperation.removeRow,
      ),
      throwsFormatException,
    );
    const single = '<table><tr><td>x</td></tr></table>';
    expect(
      () => changeEditorTable(single, 0, 0, TableOperation.removeColumn),
      throwsFormatException,
    );
    final large = html
        .parseFragment(buildEditorTable(20, 10))
        .querySelector('table')!
        .outerHtml;
    for (final operation in [TableOperation.addRow, TableOperation.addColumn]) {
      expect(
        () => changeEditorTable(large, 0, 0, operation),
        throwsFormatException,
      );
    }
  });
  test(
    'reject unsupported or stale snapshots without returning modified content',
    () {
      for (final invalid in [
        '<table><tr><td colspan="11">x</td></tr></table>',
        '<table><tr><td>A</td></tr><tr><td>B</td><td>C</td></tr></table>',
        '<table><tr><td><table><tr><td>x</td></tr></table></td></tr></table>',
        '<p>not a table</p>',
        'outside<table><tr><td>x</td></tr></table>',
      ]) {
        expect(
          () => changeEditorTable(invalid, 0, 0, TableOperation.addRow),
          throwsFormatException,
        );
      }
      expect(
        () => changeEditorTable(source, -1, 0, TableOperation.addRow),
        throwsFormatException,
      );
      expect(
        () => changeEditorTable(source, 0, 2, TableOperation.removeColumn),
        throwsFormatException,
      );
    },
  );
}
