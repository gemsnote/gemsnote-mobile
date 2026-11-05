import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'rich_text_style.dart';

bool isSafeEditorLink(String value) {
  if (value.isEmpty ||
      value.trim() != value ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

bool isSafeEditorImage(String value) {
  if (isSafeEditorLink(value)) return true;
  // Relative media references are retained, but never requested by WebView.
  return RegExp(
    r'^/(?:api2/file/getImage|file/outputImage|api/file/getImage)\?fileId=[0-9a-fA-F]{24}$',
  ).hasMatch(value);
}

/// Eligibility, not sanitization: unsupported markup must remain in source mode.
/// Separate from conflict-copy policy: hyperlinks do not imply safe file copying.
bool supportsVisualHtml(String source) {
  const tags = {
    'p',
    'div',
    'span',
    'font',
    'br',
    'hr',
    'b',
    'strong',
    'i',
    'em',
    'u',
    's',
    'strike',
    'del',
    'blockquote',
    'pre',
    'code',
    'ul',
    'ol',
    'li',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'a',
    'img',
    'table',
    'caption',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
  };
  final parser = html.HtmlParser(source);
  final fragment = parser.parseFragment();
  if (parser.errors.isNotEmpty) return false;
  bool safe(dom.Node node, int depth) {
    if (depth > 64) return false;
    if (node is dom.Text) return true;
    if (node is! dom.Element || !tags.contains(node.localName)) return false;
    if (node.localName == 'img' &&
        !isSafeEditorImage(node.attributes['src'] ?? '')) {
      return false;
    }
    for (final attribute in node.attributes.entries) {
      if (node.localName == 'img') {
        final valid = switch (attribute.key) {
          'src' => isSafeEditorImage(attribute.value),
          'alt' || 'title' => !attribute.value.contains('\u0000'),
          'width' || 'height' =>
            RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(attribute.value) &&
                int.parse(attribute.value) <= 4096,
          _ => false,
        };
        if (!valid) return false;
        continue;
      }

      if (attribute.key == 'style') {
        if (RichTextStyle.parse(attribute.value) == null) return false;
        continue;
      }
      if (attribute.key == 'align' &&
          {
            'p',
            'div',
            'td',
            'th',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
          }.contains(node.localName)) {
        if (!{
          'left',
          'right',
          'center',
          'justify',
        }.contains(attribute.value.toLowerCase())) {
          return false;
        }
        continue;
      }
      if (node.localName == 'font') {
        final valid = switch (attribute.key) {
          'color' =>
            RichTextStyle.parseColor(attribute.value.toLowerCase()) != null,
          'size' => RegExp(r'^[1-7]$').hasMatch(attribute.value),
          'face' =>
            RichTextStyle.parseFontFamily(attribute.value.toLowerCase()) !=
                null,
          _ => false,
        };
        if (!valid) return false;
        continue;
      }

      if ({'td', 'th'}.contains(node.localName) &&
          {'rowspan', 'colspan'}.contains(attribute.key)) {
        if (!RegExp(r'^[1-9][0-9]?$').hasMatch(attribute.value)) return false;
        final span = int.parse(attribute.value);
        if (span > (attribute.key == 'rowspan' ? 20 : 10)) return false;
        continue;
      }
      if (node.localName != 'a' ||
          attribute.key != 'href' ||
          !isSafeEditorLink(attribute.value)) {
        return false;
      }
    }
    return node.nodes.every((child) => safe(child, depth + 1));
  }

  return fragment.nodes.every((node) => safe(node, 0));
}
