import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/editor_table_operations.dart';
import 'package:gemsnote/ui/visual_html_policy.dart';
import 'package:html/parser.dart' as html;

void main() {
  const basic =
      '<table><caption>标题</caption><tbody><tr><td><b>A</b></td><td>B</td></tr><tr><td>C</td><td>D</td></tr></tbody></table>';
  const merged =
      '<table><tbody><tr><td rowspan="2">A</td><td>B</td></tr><tr><td>C</td></tr></tbody></table>';
  test('merge in both directions and split preserve all rich content', () {
    var value = changeEditorTable(basic, 0, 0, TableOperation.mergeRight);
    value = changeEditorTable(value, 1, 0, TableOperation.mergeRight);
    value = changeEditorTable(value, 0, 0, TableOperation.mergeDown);
    var table = html.parseFragment(value);
    expect(table.querySelectorAll('td'), hasLength(1));
    expect(table.querySelector('td')!.attributes, {
      'rowspan': '2',
      'colspan': '2',
    });
    expect(table.querySelector('td')!.text, 'ABCD');
    expect(table.querySelector('b')!.text, 'A');
    value = changeEditorTable(value, 0, 0, TableOperation.splitCell);
    table = html.parseFragment(value);
    expect(table.querySelectorAll('td'), hasLength(4));
    expect(table.querySelector('td')!.text, 'ABCD');
    expect(table.querySelector('td')!.attributes, isEmpty);
    expect(table.querySelector('caption')!.text, '标题');
    expect(supportsVisualHtml(value), isTrue);
  });
  test(
    'insert inside rowspan expands span without inserting an overlapping cell',
    () {
      final result = html.parseFragment(
        changeEditorTable(merged, 0, 1, TableOperation.addRow),
      );
      expect(result.querySelector('td')!.attributes['rowspan'], '3');
      expect(result.querySelectorAll('tr')[1].children, hasLength(1));
      expect(result.querySelectorAll('tr').last.text, 'C');
    },
  );
  test(
    'delete row containing rowspan origin moves content to surviving row',
    () {
      final result = html.parseFragment(
        changeEditorTable(merged, 0, 1, TableOperation.removeRow),
      );
      expect(result.querySelectorAll('tr'), hasLength(1));
      expect(result.querySelector('tr')!.text, 'AC');
      expect(result.querySelector('td')!.attributes, isEmpty);
    },
  );
  test('DOM cell index resolves past rowspans for column operations', () {
    final result = html.parseFragment(
      changeEditorTable(merged, 1, 0, TableOperation.removeColumn),
    );
    expect(result.querySelectorAll('td'), hasLength(1));
    expect(result.querySelector('td')!.text, 'A');
    final inserted = html.parseFragment(
      changeEditorTable(merged, 1, 0, TableOperation.addColumn),
    );
    expect(inserted.querySelectorAll('tr')[0].children, hasLength(3));
    expect(inserted.querySelectorAll('tr')[1].children, hasLength(2));
  });
  test('insertion inside colspan extends it; deletion retains spanning content', () {
    const source =
        '<table><tr><td colspan="2">AB</td></tr><tr><td>C</td><td>D</td></tr></table>';
    final inserted = html.parseFragment(
      changeEditorTable(source, 1, 0, TableOperation.addColumn),
    );
    expect(inserted.querySelector('td')!.attributes['colspan'], '3');
    expect(inserted.querySelectorAll('tr')[1].children, hasLength(3));
    final removed = html.parseFragment(
      changeEditorTable(source, 0, 0, TableOperation.removeColumn),
    );
    expect(removed.querySelector('td')!.text, 'AB');
    expect(removed.querySelector('td')!.attributes, isEmpty);
    expect(removed.querySelectorAll('tr')[1].text, 'D');
  });
  test('invalid geometry, section crossings and incompatible merge remain unchanged', () {
    for (final source in [
      '<table><tr><td rowspan="3">A</td></tr></table>',
      '<table><tr><td>A</td><td rowspan="2">B</td></tr><tr><td colspan="2">C</td></tr></table>',
      '<table><thead><tr><th rowspan="2">A</th></tr></thead><tbody><tr></tr></tbody></table>',
      '<table><tr><td colspan="2">A</td></tr><tr><td>B</td></tr></table>',
    ]) {
      expect(
        () => changeEditorTable(source, 0, 0, TableOperation.addRow),
        throwsFormatException,
      );
    }
    expect(
      () => changeEditorTable(merged, 0, 0, TableOperation.mergeRight),
      throwsFormatException,
    );
    expect(
      () => changeEditorTable(
        '<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>B</td></tr></tbody></table>',
        0,
        0,
        TableOperation.mergeDown,
      ),
      throwsFormatException,
    );
    expect(
      () => changeEditorTable(basic, 0, 0, TableOperation.splitCell),
      throwsFormatException,
    );
  });
  test('span attributes are bounded and never permit executable markup', () {
    for (final value in ['0', '-1', '21', '1.5', '2px', '999999', ' 2']) {
      expect(
        supportsVisualHtml(
          '<table><tr><td rowspan="$value">A</td></tr></table>',
        ),
        isFalse,
      );
    }
    expect(
      supportsVisualHtml(
        '<table><tr><td colspan="2" onclick="bad()">A</td></tr></table>',
      ),
      isFalse,
    );
    expect(supportsVisualHtml(merged), isTrue);
  });
}
