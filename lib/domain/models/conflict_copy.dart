import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// Conservative eligibility check, not a sanitizer. Copy the original source
/// unchanged only when it cannot carry file references requiring ownership moves.
bool canCopyConflictBody(String content, {required bool isMarkdown}) {
  if (isMarkdown) return !RegExp(r'[\[<]').hasMatch(content);
  const tags = {
    'p',
    'div',
    'span',
    'br',
    'hr',
    'b',
    'strong',
    'i',
    'em',
    'u',
    's',
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
  };
  final parser = html.HtmlParser(content);
  final fragment = parser.parseFragment();
  if (parser.errors.isNotEmpty) return false;
  bool safe(dom.Node node, int depth) {
    if (depth > 64) return false;
    if (node is dom.Text) return true;
    if (node is! dom.Element ||
        !tags.contains(node.localName) ||
        node.attributes.isNotEmpty) {
      return false;
    }
    return node.nodes.every((child) => safe(child, depth + 1));
  }

  return fragment.nodes.every((node) => safe(node, 0));
}
