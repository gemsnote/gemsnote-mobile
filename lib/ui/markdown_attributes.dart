import 'package:markdown/markdown.dart' as md;

// Match the legacy Markdown Extra ID/class syntax, never arbitrary HTML/CSS.
final _attributes = RegExp(
  r'(?:^|[ \t]+)\{[ \t]*((?:[#.][-_:a-zA-Z0-9]+[ \t]*)+)\}[ \t]*$',
);

void _apply(md.Element element, Match match) {
  final values = RegExp(r'[#.][-_:a-zA-Z0-9]+')
      .allMatches(match[1]!)
      .map((token) => token[0]!);
  final ids = values.where((value) => value.startsWith('#'));
  if (ids.isNotEmpty) element.attributes['id'] = ids.first.substring(1);
  final classes = values
      .where((value) => value.startsWith('.'))
      .map((value) => value.substring(1));
  if (classes.isNotEmpty) {
    element.attributes['class'] = classes.toSet().join(' ');
  }
}

md.Node? _heading(md.Node? node, {bool atx = false}) {
  if (node is! md.Element || node.children?.length != 1) return node;
  final child = node.children!.single;
  if (child is! md.UnparsedContent) return node;
  final match = _attributes.firstMatch(child.textContent);
  if (match == null) return node;
  var body = child.textContent.substring(0, match.start);
  if (atx) body = body.replaceFirst(RegExp(r'[ \t]+#+[ \t]*$'), '');
  node.children![0] = md.UnparsedContent(body);
  _apply(node, match);
  return node;
}

class AttributeHeadingSyntax extends md.HeaderSyntax {
  const AttributeHeadingSyntax();
  @override
  md.Node parse(md.BlockParser parser) =>
      _heading(super.parse(parser), atx: true)!;
}

class AttributeSetextHeadingSyntax extends md.SetextHeaderSyntax {
  const AttributeSetextHeadingSyntax();
  @override
  md.Node? parse(md.BlockParser parser) => _heading(super.parse(parser));
}

class AttributeCodeFenceSyntax extends md.FencedCodeBlockSyntax {
  const AttributeCodeFenceSyntax();
  @override
  md.Node parse(md.BlockParser parser) {
    final opening = parser.current.content;
    final match = _attributes.firstMatch(opening);
    final node = super.parse(parser) as md.Element;
    if (match == null) return node;
    _apply(node, match);
    // Recompute language from the original opening line without the attribute
    // suffix: an attribute-only fence must not become "language-{#id}".
    final info = opening
        .substring(0, match.start)
        .replaceFirst(RegExp(r'^ {0,3}(?:`{3,}|~{3,})'), '')
        .trim();
    final code = node.children!.single as md.Element;
    code.attributes.remove('class');
    if (info.isNotEmpty) {
      code.attributes['class'] = 'language-${info.split(RegExp(r'\s+')).first}';
    }
    node.attributes.remove('data-metadata');
    return node;
  }
}
