import 'package:markdown/markdown.dart' as md;

/// Markdown Extra definitions used by the legacy mobile editor. Emit standard
/// renderer blocks so nested links/images retain the account-aware handlers.
class DefinitionListSyntax extends md.BlockSyntax {
  const DefinitionListSyntax();

  @override
  RegExp get pattern => RegExp(r'^ {0,3}\S');

  static final _definition = RegExp(r'^ {0,3}:[ \t]+(.*)$');
  static final _otherBlock = RegExp(
    r'^ {0,3}(?:[>#`~<:]|[-*+]\s|\d+[.)]\s|\[.*\]:|[-=_*]{3,}\s*$|\|?\s*:?-{3,})',
  );

  int? _definitionOffset(md.BlockParser parser) {
    // Bound lookahead on long ordinary paragraphs. A list of more than 64
    // consecutive terms remains readable as source instead of quadratic work.
    for (var offset = 0; offset <= 64; offset++) {
      final line = parser.peek(offset)?.content;
      if (line == null) return null;
      if (offset > 0 && _definition.hasMatch(line)) return offset;
      if (line.trim().isEmpty) {
        return offset > 0 &&
                _definition.hasMatch(parser.peek(offset + 1)?.content ?? '')
            ? offset + 1
            : null;
      }
      if (!pattern.hasMatch(line) || _otherBlock.hasMatch(line)) return null;
    }
    return null;
  }

  @override
  bool canParse(md.BlockParser parser) => _definitionOffset(parser) != null;

  @override
  bool canEndBlock(md.BlockParser parser) => false;

  @override
  md.Node parse(md.BlockParser parser) {
    final offset = _definitionOffset(parser)!;
    final blocks = <md.Node>[];
    for (var index = 0; index < offset; index++) {
      final term = parser.current.content.trim();
      if (term.isNotEmpty) {
        blocks.add(
          md.Element('p', [
            md.Element('strong', [md.UnparsedContent(term)]),
          ]),
        );
      }
      parser.advance();
    }
    while (!parser.isDone) {
      final match = _definition.firstMatch(parser.current.content);
      if (match == null) break;
      final lines = <md.Line>[md.Line(match[1]!)];
      parser.advance();
      while (!parser.isDone) {
        final line = parser.current.content;
        if (_definition.hasMatch(line)) break;
        if (line.trim().isEmpty) {
          final next = parser.next?.content ?? '';
          if (_definition.hasMatch(next)) {
            parser.advance();
            break;
          }
          if (!next.startsWith('    ') && !next.startsWith('\t')) break;
          lines.add(md.Line(''));
        } else if (line.startsWith('    ')) {
          lines.add(md.Line(line.substring(4)));
        } else if (line.startsWith('\t')) {
          lines.add(md.Line(line.substring(1)));
        } else if (_otherBlock.hasMatch(line)) {
          break;
        } else {
          lines.add(md.Line(line));
        }
        parser.advance();
      }
      blocks.add(
        md.Element(
          'blockquote',
          md.BlockParser(lines, parser.document).parseLines(),
        ),
      );
    }
    return md.Element('section', blocks);
  }
}
