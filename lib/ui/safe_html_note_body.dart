import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'cached_markdown_image.dart';
import 'markdown_note_body.dart' show copyNoteText;
import 'note_link_dialog.dart';
import 'spanning_table.dart';
import 'rich_text_style.dart';
import '../services/note_link_opener.dart';

/// Native HTML preview; optional media callbacks enforce account-scoped access.
/// Unknown wrappers retain their text; active/embedded content is omitted.
class SafeHtmlNoteBody extends StatelessWidget {
  const SafeHtmlNoteBody({
    required this.content,
    this.loadCachedImage,
    this.downloadImage,
    this.canDownloadImage,
    this.linkOpener,
    super.key,
  });

  final String content;
  final NoteLinkOpener? linkOpener;
  final CachedImageLoader? loadCachedImage;
  final Future<Uint8List> Function(Uri)? downloadImage;
  final bool Function(Uri)? canDownloadImage;

  static const _omitted = {
    'script',
    'style',
    'iframe',
    'object',
    'embed',
    'template',
    'head',
    'svg',
    'math',
    'noscript',
    'form',
    'input',
    'button',
    'select',
    'textarea',
  };
  static const _blocks = {
    'p',
    'div',
    'section',
    'article',
    'header',
    'footer',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'pre',
    'ul',
    'ol',
    'li',
    'tr',
    'table',
  };

  List<String> _links(List<dom.Node> nodes) {
    final found = <String>{};
    void visit(List<dom.Node> children, int depth) {
      if (depth >= 64 || found.length >= 100) return;
      for (final node in children) {
        if (found.length >= 100) return;
        if (node is! dom.Element || _omitted.contains(node.localName)) continue;
        if (node.localName == 'a') {
          final href = node.attributes['href'];
          if (href != null && href.isNotEmpty) found.add(href);
        }
        visit(node.nodes, depth + 1);
      }
    }

    visit(nodes, 0);
    return found.toList();
  }

  RichTextStyle _style(dom.Element element) {
    final values = <String, String>{};
    final align = element.attributes['align']?.toLowerCase();
    if (align != null && RichTextStyle.parse('text-align:$align') != null) {
      values['text-align'] = align;
    }
    if (element.localName == 'font') {
      final color = element.attributes['color']?.toLowerCase();
      if (color != null && RichTextStyle.parseColor(color) != null) {
        values['color'] = color;
      }
      final family = element.attributes['face']?.toLowerCase();
      if (family != null && RichTextStyle.parseFontFamily(family) != null) {
        values['font-family'] = family;
      }
      const sizes = {
        '1': '10px',
        '2': '13px',
        '3': '16px',
        '4': '18px',
        '5': '24px',
        '6': '32px',
        '7': '48px',
      };
      final size = sizes[element.attributes['size']];
      if (size != null) values['font-size'] = size;
    }
    values.addAll(
      RichTextStyle.parse(element.attributes['style'] ?? '')?.declarations ??
          {},
    );
    return RichTextStyle(values);
  }

  RichTextStyle _cellStyle(dom.Element? element) {
    final chain = <dom.Element>[];
    var current = element;
    while (current != null && chain.length < 64) {
      chain.add(current);
      if (current.localName == 'table') break;
      current = current.parent;
    }
    return RichTextStyle({
      for (final item in chain.reversed) ..._style(item).declarations,
    });
  }

  bool _hasWidgets(InlineSpan span) =>
      span is WidgetSpan ||
      (span is TextSpan && (span.children?.any(_hasWidgets) ?? false));

  List<InlineSpan> _render(
    AppStrings strings,
    List<dom.Node> nodes, {
    int depth = 0,
    bool pre = false,
    TextStyle inheritedStyle = const TextStyle(),
    List<dom.Element>? images,
    List<dom.Element>? tables,
    double imageWidth = 0,
  }) {
    final spans = <InlineSpan>[];
    var listIndex = 0;
    for (final node in nodes) {
      if (node is dom.Text) {
        spans.add(
          TextSpan(
            text: pre ? node.data : node.data.replaceAll(RegExp(r'\s+'), ' '),
          ),
        );
        continue;
      }
      if (node is! dom.Element) continue;
      final tag = node.localName ?? '';
      if (_omitted.contains(tag)) continue;
      // Avoid unbounded recursion for hostile or accidentally deeply nested HTML.
      if (depth >= 64) {
        spans.add(TextSpan(text: strings.text('deepHtml')));
        continue;
      }
      if (tag == 'table' && tables != null) {
        final grid = HtmlTableGrid.parse(node);
        if (grid != null && grid.hasSpans) {
          tables.add(node);
          spans.add(const TextSpan(text: '\n'));
          spans.add(
            WidgetSpan(
              child: SizedBox(
                width: imageWidth,
                child: _spanningTable(
                  node,
                  grid,
                  imageWidth,
                  images,
                  depth + 1,
                  strings,
                ),
              ),
            ),
          );
          spans.add(const TextSpan(text: '\n'));
          continue;
        }
        final rows = _tableRows(node);
        if (rows != null) {
          tables.add(node);
          spans.add(const TextSpan(text: '\n'));
          spans.add(
            WidgetSpan(
              child: SizedBox(
                width: imageWidth,
                child: _table(
                  node,
                  rows,
                  imageWidth,
                  images,
                  depth + 1,
                  strings,
                ),
              ),
            ),
          );
          spans.add(const TextSpan(text: '\n'));
          continue;
        }
        spans.add(TextSpan(text: strings.text('largeTable')));
      }
      if (tag == 'img' || tag == 'video' || tag == 'audio') {
        final collected = tag == 'img' && images != null && images.length < 100;
        if (collected) {
          images.add(node);
          spans.add(const TextSpan(text: '\n'));
          spans.add(
            WidgetSpan(
              child: SizedBox(width: imageWidth, child: _image(node, strings)),
            ),
          );
          spans.add(const TextSpan(text: '\n'));
          continue;
        }
        final alt = node.attributes['alt'];
        spans.add(
          TextSpan(
            text: strings.text('missingMedia', [
              alt == null || alt.isEmpty
                  ? ''
                  : strings.locale.languageCode == 'zh'
                  ? '：$alt'
                  : ': $alt',
            ]),
          ),
        );
        continue;
      }
      if (tag == 'br' || tag == 'hr') {
        spans.add(TextSpan(text: tag == 'br' ? '\n' : '\n────────\n'));
        continue;
      }
      if (_blocks.contains(tag)) spans.add(const TextSpan(text: '\n'));
      if (tag == 'li') {
        final parent = node.parentNode;
        listIndex++;
        spans.add(
          TextSpan(
            text: parent is dom.Element && parent.localName == 'ol'
                ? '$listIndex. '
                : '• ',
          ),
        );
      }
      final heading = RegExp(r'^h[1-6]$').hasMatch(tag);
      final css = _style(node);
      final style = TextStyle(
        fontWeight: heading || tag == 'b' || tag == 'strong' || tag == 'th'
            ? FontWeight.bold
            : null,
        fontStyle: tag == 'i' || tag == 'em' || tag == 'blockquote'
            ? FontStyle.italic
            : null,
        fontFamily: tag == 'code' || tag == 'pre' ? 'monospace' : null,
        fontSize: heading ? 26 - int.parse(tag.substring(1)) * 2.0 : null,
        decoration: tag == 's' || tag == 'del' || tag == 'strike'
            ? TextDecoration.lineThrough
            : tag == 'u'
            ? TextDecoration.underline
            : null,
      ).merge(css.textStyle);
      final resolvedStyle = inheritedStyle.merge(style);
      final rendered = TextSpan(
        style: style,
        children: _render(
          strings,
          node.nodes,
          depth: depth + 1,
          pre: pre || tag == 'pre',
          inheritedStyle: resolvedStyle,
          images: images,
          tables: tag == 'table' ? null : tables,
          imageWidth: imageWidth,
        ),
      );
      if (css.alignment != null && _blocks.contains(tag) && imageWidth > 0) {
        spans.add(
          WidgetSpan(
            child: SizedBox(
              width: imageWidth,
              child: Text.rich(
                TextSpan(style: resolvedStyle, children: [rendered]),
                textAlign: css.alignment,
              ),
            ),
          ),
        );
      } else {
        spans.add(rendered);
      }
      // Addresses are selectable text only, never executable links.
      if (tag == 'a') {
        final href = node.attributes['href'];
        if (href != null && href.isNotEmpty) {
          spans.add(TextSpan(text: ' ($href)'));
        }
      }
      if (tag == 'td' || tag == 'th') spans.add(const TextSpan(text: ' | '));
      if (_blocks.contains(tag)) spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }

  List<List<dom.Element>>? _tableRows(dom.Element table) {
    if (table.querySelector('table') != null) return null;
    final rows = <List<dom.Element>>[];
    var cellCount = 0;
    final rowNodes = <dom.Element>[];
    for (final child in table.children) {
      if (child.localName == 'tr') {
        rowNodes.add(child);
      } else if ({'thead', 'tbody', 'tfoot'}.contains(child.localName)) {
        if (child.children.any((node) => node.localName != 'tr')) return null;
        rowNodes.addAll(child.children);
      } else if (child.localName != 'caption') {
        return null;
      }
    }
    for (final row in rowNodes) {
      final cells = row.children;
      if (cells.isEmpty ||
          cells.length > 20 ||
          cells.any(
            (cell) =>
                !{'td', 'th'}.contains(cell.localName) ||
                (cell.attributes['colspan'] ?? '1') != '1' ||
                (cell.attributes['rowspan'] ?? '1') != '1',
          )) {
        return null;
      }
      rows.add(cells);
      cellCount += cells.length;
      if (rows.length > 100 || cellCount > 1000) return null;
    }
    return rows.isEmpty ? null : rows;
  }

  Widget _spanningTable(
    dom.Element table,
    HtmlTableGrid grid,
    double width,
    List<dom.Element>? images,
    int depth,
    AppStrings strings,
  ) {
    final cellWidth = (width / grid.columns).clamp(140.0, 320.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final caption in table.children.where(
          (node) => node.localName == 'caption',
        ))
          Text.rich(
            TextSpan(children: _render(strings, caption.nodes, depth: depth)),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SpanningTable(
            grid: grid,
            columnWidth: cellWidth,
            children: [
              for (final cell in grid.cells)
                Container(
                  alignment: Alignment.topLeft,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cell.element?.localName == 'th'
                        ? const Color(0xffe5eee8)
                        : Colors.transparent,
                    border: Border.all(
                      color: const Color(0xff527b68),
                      width: 0.5,
                    ),
                  ),
                  child: Text.rich(
                    textAlign: cell.element == null
                        ? null
                        : _cellStyle(cell.element).alignment,
                    TextSpan(
                      children: _render(
                        strings,
                        cell.element?.nodes ?? [],
                        depth: depth + 1,
                        images: images,
                        imageWidth: cellWidth * cell.columns - 16,
                      ),
                    ),
                    style:
                        TextStyle(
                          fontSize: 16,
                          height: 1.65,
                          fontWeight: cell.element?.localName == 'th'
                              ? FontWeight.bold
                              : null,
                        ).merge(
                          cell.element == null
                              ? null
                              : _cellStyle(cell.element).textStyle,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _table(
    dom.Element table,
    List<List<dom.Element>> rows,
    double availableWidth,
    List<dom.Element>? images,
    int depth,
    AppStrings strings,
  ) {
    final columns = rows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    final cellWidth = (availableWidth / columns).clamp(140.0, 320.0);
    final caption = table.children.where((node) => node.localName == 'caption');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final node in caption)
          Text.rich(
            TextSpan(children: _render(strings, node.nodes, depth: depth)),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: FixedColumnWidth(cellWidth),
            border: TableBorder.all(color: const Color(0xff527b68)),
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            children: [
              for (final row in rows)
                TableRow(
                  children: [
                    for (var index = 0; index < columns; index++)
                      if (index >= row.length)
                        const SizedBox()
                      else
                        ColoredBox(
                          color: row[index].localName == 'th'
                              ? const Color(0xffe5eee8)
                              : Colors.transparent,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text.rich(
                              textAlign: _cellStyle(row[index]).alignment,
                              TextSpan(
                                children: _render(
                                  strings,
                                  row[index].nodes,
                                  depth: depth + 1,
                                  images: images,
                                  imageWidth: cellWidth - 16,
                                ),
                              ),
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.65,
                                fontWeight: row[index].localName == 'th'
                                    ? FontWeight.bold
                                    : null,
                              ).merge(_cellStyle(row[index]).textStyle),
                            ),
                          ),
                        ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final strings = AppStrings.of(context);
        final images = <dom.Element>[];
        final tables = <dom.Element>[];
        final nodes = html.parseFragment(content).nodes;
        final links = _links(nodes);
        final baseStyle = DefaultTextStyle.of(context).style
            .copyWith(fontSize: 16, height: 1.65);
        final spans = _render(
          strings,
          nodes,
          inheritedStyle: baseStyle,
          images: loadCachedImage == null ? null : images,
          tables: tables,
          imageWidth: constraints.maxWidth,
        );
        final text = TextSpan(style: baseStyle, children: spans);
        return SingleChildScrollView(
          // SelectableText supports only TextSpans. SelectionArea with Text.rich
          // retains native text selection around embedded images and tables.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              !_hasWidgets(text)
                  ? SelectableText.rich(text)
                  : SelectionArea(child: Text.rich(text)),
              if (links.isNotEmpty)
                ExpansionTile(
                  title: Text(tr(context, 'm0353', [links.length])),
                  subtitle: Text(tr(context, 'm0354')),
                  children: [
                    for (final href in links)
                      ListTile(
                        leading: const Icon(Icons.link),
                        title: Text(
                          href,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (dialogContext) => NoteLinkDialog(
                            href: href,
                            opener: linkOpener,
                            onCopy: () => copyNoteText(dialogContext, href),
                          ),
                        ),
                      ),
                    if (links.length == 100)
                      Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(tr(context, 'm0355')),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _image(dom.Element element, AppStrings strings) {
    final uri = Uri.tryParse(element.attributes['src'] ?? '');
    if (uri == null || uri.toString().isEmpty) {
      return Text(strings.text('invalidImageAddress'));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CachedMarkdownImage(
        uri: uri,
        alt: element.attributes['alt'],
        load: loadCachedImage!,
        download: downloadImage != null && canDownloadImage?.call(uri) == true
            ? () => downloadImage!(uri)
            : null,
      ),
    );
  }
}
