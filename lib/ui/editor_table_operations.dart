import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'visual_html_policy.dart';

enum TableOperation {
  addRow,
  addColumn,
  removeRow,
  removeColumn,
  mergeRight,
  mergeDown,
  splitCell,
}

class _Cell {
  _Cell(this.element, this.row, this.column, this.height, this.width);
  final Element element;
  int row, column, height, width;
  int get bottom => row + height;
  int get right => column + width;
}

/// Transform a snapshot, never the live editor. The selected column is the DOM
/// cellIndex; logical grid coordinates account for all preceding merged cells.
String changeEditorTable(
  String source,
  int rowIndex,
  int columnIndex,
  TableOperation operation,
) {
  if (!supportsVisualHtml(source)) throw const FormatException('不支持此表格格式');
  final fragment = html.parseFragment(source);
  if (fragment.children.length != 1 ||
      fragment.children.single.localName != 'table') {
    throw const FormatException('请选择表格单元格');
  }
  final table = fragment.children.single;
  if (fragment.nodes.any(
    (node) => node != table && (node is! Text || node.data.trim().isNotEmpty),
  )) {
    throw const FormatException('表格快照包含额外内容');
  }
  final rows = table.querySelectorAll('tr');
  if (table.querySelector('table') != null ||
      rows.isEmpty ||
      rows.length > 20) {
    throw const FormatException('仅支持最多 20 行的非嵌套表格');
  }
  if (rowIndex < 0 ||
      rowIndex >= rows.length ||
      columnIndex < 0 ||
      columnIndex >= rows[rowIndex].children.length) {
    throw const FormatException('单元格位置已失效，请重新选择');
  }
  final selectedElement = rows[rowIndex].children[columnIndex];
  final grid = List.generate(rows.length, (_) => List<_Cell?>.filled(10, null));
  final cells = <_Cell>[];
  var columns = 0;
  for (var r = 0; r < rows.length; r++) {
    var c = 0;
    for (final element in rows[r].children) {
      if (!{'td', 'th'}.contains(element.localName)) {
        throw const FormatException('表格包含非单元格内容');
      }
      while (c < 10 && grid[r][c] != null) {
        c++;
      }
      final h = int.parse(element.attributes['rowspan'] ?? '1');
      final w = int.parse(element.attributes['colspan'] ?? '1');
      if (c + w > 10 ||
          r + h > rows.length ||
          rows
              .sublist(r, r + h)
              .any((row) => row.parentNode != rows[r].parentNode)) {
        throw const FormatException('合并单元格超出表格边界或跨越表头分区');
      }
      final cell = _Cell(element, r, c, h, w);
      for (var y = r; y < r + h; y++) {
        for (var x = c; x < c + w; x++) {
          if (grid[y][x] != null) throw const FormatException('合并单元格重叠');
          grid[y][x] = cell;
        }
      }
      cells.add(cell);
      c += w;
      if (c > columns) columns = c;
    }
  }
  if (columns == 0 ||
      grid.any((row) => row.take(columns).any((cell) => cell == null))) {
    throw const FormatException('表格存在缺失单元格');
  }
  final selected = cells.singleWhere((cell) => cell.element == selectedElement);
  Element emptyCell(String tag) => Element.tag(tag)..append(Element.tag('br'));
  void merge(_Cell other) {
    // Separate blocks keep both cells readable, including lists and paragraphs.
    final first = Element.tag('div')
      ..nodes.addAll(selected.element.nodes.toList());
    final second = Element.tag('div')
      ..nodes.addAll(other.element.nodes.toList());
    selected.element.nodes.clear();
    selected.element
      ..append(first)
      ..append(second);
    cells.remove(other);
  }

  switch (operation) {
    case TableOperation.addRow:
      if (rows.length == 20) throw const FormatException('最多支持 20 行');
      final at = rowIndex + 1;
      for (final cell in cells) {
        if (cell.row < at && cell.bottom > at) {
          cell.height++;
        } else if (cell.row >= at) {
          cell.row++;
        }
      }
      final row = Element.tag('tr');
      final parent = rows[rowIndex].parentNode!;
      parent.nodes.insert(parent.nodes.indexOf(rows[rowIndex]) + 1, row);
      rows.insert(at, row);
      for (var c = 0; c < columns; c++) {
        if (!cells.any(
          (cell) =>
              cell.row <= at &&
              cell.bottom > at &&
              cell.column <= c &&
              cell.right > c,
        )) {
          cells.add(
            _Cell(
              emptyCell(grid[rowIndex][c]!.element.localName!),
              at,
              c,
              1,
              1,
            ),
          );
        }
      }
    case TableOperation.addColumn:
      if (columns == 10) throw const FormatException('最多支持 10 列');
      final at = selected.right;
      for (final cell in cells) {
        if (cell.column < at && cell.right > at) {
          cell.width++;
        } else if (cell.column >= at) {
          cell.column++;
        }
      }
      for (var r = 0; r < rows.length; r++) {
        if (!cells.any(
          (cell) =>
              cell.row <= r &&
              cell.bottom > r &&
              cell.column <= at &&
              cell.right > at,
        )) {
          cells.add(
            _Cell(emptyCell(grid[r][at - 1]!.element.localName!), r, at, 1, 1),
          );
        }
      }
    case TableOperation.removeRow:
      if (rows.length == 1) throw const FormatException('不能删除最后一行');
      cells.removeWhere((cell) => cell.row == rowIndex && cell.height == 1);
      for (final cell in cells) {
        if (cell.row <= rowIndex && cell.bottom > rowIndex) {
          cell.height--;
        } else if (cell.row > rowIndex) {
          cell.row--;
        }
      }
      rows.removeAt(rowIndex).remove();
    case TableOperation.removeColumn:
      if (columns == 1) throw const FormatException('不能删除最后一列');
      final at = selected.column;
      cells.removeWhere((cell) => cell.column == at && cell.width == 1);
      for (final cell in cells) {
        if (cell.column <= at && cell.right > at) {
          cell.width--;
        } else if (cell.column > at) {
          cell.column--;
        }
      }
    case TableOperation.mergeRight:
      final other = selected.right < columns
          ? grid[selected.row][selected.right]
          : null;
      if (other == null ||
          other.row != selected.row ||
          other.height != selected.height) {
        throw const FormatException('右侧单元格高度不一致，无法合并');
      }
      selected.width += other.width;
      merge(other);
    case TableOperation.mergeDown:
      final other = selected.bottom < rows.length
          ? grid[selected.bottom][selected.column]
          : null;
      if (other == null ||
          other.column != selected.column ||
          other.width != selected.width ||
          rows[other.row].parentNode != rows[selected.row].parentNode) {
        throw const FormatException('下方单元格宽度或分区不一致，无法合并');
      }
      selected.height += other.height;
      merge(other);
    case TableOperation.splitCell:
      if (selected.width == 1 && selected.height == 1) {
        throw const FormatException('当前单元格未合并');
      }
      for (var r = selected.row; r < selected.bottom; r++) {
        for (var c = selected.column; c < selected.right; c++) {
          if (r != selected.row || c != selected.column) {
            cells.add(
              _Cell(emptyCell(selected.element.localName!), r, c, 1, 1),
            );
          }
        }
      }
      selected.height = selected.width = 1;
  }
  // Keep the existing table/sections/rows and all surviving cell contents.
  for (final row in rows) {
    row.nodes.clear();
  }
  cells.sort(
    (a, b) =>
        a.row == b.row ? a.column.compareTo(b.column) : a.row.compareTo(b.row),
  );
  for (final cell in cells) {
    if (cell.height == 1) {
      cell.element.attributes.remove('rowspan');
    } else {
      cell.element.attributes['rowspan'] = '${cell.height}';
    }
    if (cell.width == 1) {
      cell.element.attributes.remove('colspan');
    } else {
      cell.element.attributes['colspan'] = '${cell.width}';
    }
    rows[cell.row].append(cell.element);
  }
  return table.outerHtml;
}
