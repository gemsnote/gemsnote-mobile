import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

class HtmlGridCell {
  const HtmlGridCell(
    this.element,
    this.row,
    this.column,
    this.rows,
    this.columns,
  );
  final dom.Element? element;
  final int row, column, rows, columns;
}

class HtmlTableGrid {
  const HtmlTableGrid(this.rows, this.columns, this.cells);
  final int rows, columns;
  final List<HtmlGridCell> cells;
  bool get hasSpans => cells.any((cell) => cell.rows > 1 || cell.columns > 1);

  static HtmlTableGrid? parse(dom.Element table) {
    if (table.querySelector('table') != null) return null;
    final rows = <dom.Element>[];
    for (final child in table.children) {
      if (child.localName == 'tr') {
        rows.add(child);
      } else if ({'thead', 'tbody', 'tfoot'}.contains(child.localName)) {
        if (child.children.any((node) => node.localName != 'tr')) return null;
        rows.addAll(child.children);
      } else if (child.localName != 'caption') {
        return null;
      }
    }
    if (rows.isEmpty || rows.length > 100) return null;
    final grid = List.generate(
      rows.length,
      (_) => List<bool>.filled(20, false),
    );
    final cells = <HtmlGridCell>[];
    var columns = 0;
    for (var r = 0; r < rows.length; r++) {
      var c = 0;
      for (final node in rows[r].children) {
        if (!{'td', 'th'}.contains(node.localName) || cells.length >= 1000) {
          return null;
        }
        int? span(String key) {
          final value = node.attributes[key] ?? '1';
          return RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(value)
              ? int.tryParse(value)
              : null;
        }

        final h = span('rowspan'), w = span('colspan');
        while (c < 20 && grid[r][c]) {
          c++;
        }
        if (h == null ||
            w == null ||
            c + w > 20 ||
            r + h > rows.length ||
            rows
                .sublist(r, r + h)
                .any((row) => row.parentNode != rows[r].parentNode)) {
          return null;
        }
        for (var y = r; y < r + h; y++) {
          for (var x = c; x < c + w; x++) {
            if (grid[y][x]) return null;
            grid[y][x] = true;
          }
        }
        cells.add(HtmlGridCell(node, r, c, h, w));
        c += w;
        columns = math.max(columns, c);
      }
    }
    if (columns == 0) return null;
    // Short rows retain the same blank-cell behavior as the ordinary preview.
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < columns; c++) {
        if (!grid[r][c]) cells.add(HtmlGridCell(null, r, c, 1, 1));
      }
    }
    return HtmlTableGrid(rows.length, columns, cells);
  }
}

/// Native variable-height cells. Rowspan height is distributed over the rows it
/// covers, and children are laid out again at their final size for hit testing.
class SpanningTable extends MultiChildRenderObjectWidget {
  const SpanningTable({
    required this.grid,
    required this.columnWidth,
    required super.children,
    super.key,
  });
  final HtmlTableGrid grid;
  final double columnWidth;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSpanningTable(grid, columnWidth);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderSpanningTable).configure(grid, columnWidth);
  }
}

class _CellData extends ContainerBoxParentData<RenderBox> {}

class _RenderSpanningTable extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CellData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CellData> {
  _RenderSpanningTable(this.grid, this.columnWidth);
  HtmlTableGrid grid;
  double columnWidth;
  void configure(HtmlTableGrid value, double width) {
    grid = value;
    columnWidth = width;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CellData) child.parentData = _CellData();
  }

  List<double> heights({required bool dry}) {
    final result = List<double>.filled(grid.rows, 40);
    var child = firstChild;
    var index = 0;
    while (child != null) {
      final cell = grid.cells[index++];
      final limits = BoxConstraints.tightFor(width: columnWidth * cell.columns);
      final Size measured;
      if (dry) {
        measured = child.getDryLayout(limits);
      } else {
        child.layout(limits, parentUsesSize: true);
        measured = child.size;
      }
      var existing = 0.0;
      for (var r = cell.row; r < cell.row + cell.rows; r++) {
        existing += result[r];
      }
      if (measured.height > existing) {
        final extra = (measured.height - existing) / cell.rows;
        for (var r = cell.row; r < cell.row + cell.rows; r++) {
          result[r] += extra;
        }
      }
      child = childAfter(child);
    }
    return result;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    Size(
      columnWidth * grid.columns,
      heights(dry: true).fold(0.0, (a, b) => a + b),
    ),
  );
  @override
  void performLayout() {
    final rowHeights = heights(dry: false);
    final tops = <double>[0];
    for (final height in rowHeights) {
      tops.add(tops.last + height);
    }
    size = constraints.constrain(Size(columnWidth * grid.columns, tops.last));
    var child = firstChild;
    var index = 0;
    while (child != null) {
      final cell = grid.cells[index++];
      child.layout(
        BoxConstraints.tight(
          Size(
            columnWidth * cell.columns,
            tops[cell.row + cell.rows] - tops[cell.row],
          ),
        ),
        parentUsesSize: true,
      );
      (child.parentData! as _CellData).offset = Offset(
        columnWidth * cell.column,
        tops[cell.row],
      );
      child = childAfter(child);
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => columnWidth * grid.columns;
  @override
  double computeMaxIntrinsicWidth(double height) => columnWidth * grid.columns;
  @override
  double computeMinIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints()).height;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);
  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
