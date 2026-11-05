import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_attributes.dart';
import 'markdown_definition_list.dart';
import 'markdown_math.dart';
import 'markdown_mermaid.dart';

const noteMarkdownBlocks = <md.BlockSyntax>[
  MathBlockSyntax(),
  AttributeHeadingSyntax(),
  AttributeSetextHeadingSyntax(),
  MermaidFenceSyntax(),
  DefinitionListSyntax(),
];

/// Resolve only a fragment in this document; never fetch another document.
List<md.Node>? markdownAnchor(String source, String href) {
  if (!href.startsWith('#') || href.length == 1) return null;
  final raw = href.substring(1);
  String decoded;
  try {
    decoded = Uri.decodeComponent(raw);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  final nodes = md.Document(
    blockSyntaxes: noteMarkdownBlocks,
    inlineSyntaxes: [MathInlineSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.split('\n'));
  List<md.Node>? find(
    List<md.Node> children,
    md.Element? paragraph,
    int depth,
  ) {
    if (depth > 128) return null;
    for (var index = 0; index < children.length; index++) {
      final node = children[index];
      if (node is! md.Element) continue;
      final id = node.attributes['id'];
      if (id == raw || id == decoded) {
        if (id!.startsWith('fnref-') && paragraph != null) return [paragraph];
        if (node.tag == 'li') return [md.Element('section', node.children)];
        if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
          final level = int.parse(node.tag.substring(1));
          final section = <md.Node>[node];
          for (final sibling in children.skip(index + 1)) {
            if (sibling is md.Element &&
                RegExp(r'^h[1-6]$').hasMatch(sibling.tag) &&
                int.parse(sibling.tag.substring(1)) <= level) {
              break;
            }
            section.add(sibling);
          }
          return section;
        }
        return [node];
      }
      final result = find(
        node.children ?? [],
        node.tag == 'p' ? node : paragraph,
        depth + 1,
      );
      if (result != null) return result;
    }
    return null;
  }

  return find(nodes, null, 0);
}

/// Renders the selected AST directly, preserving inline math, reference links
/// and footnotes already resolved in the complete document.
class MarkdownAnchorPreview extends StatefulWidget {
  const MarkdownAnchorPreview({
    required this.nodes,
    required this.imageBuilder,
    required this.onLink,
    super.key,
  });
  final List<md.Node> nodes;
  final MarkdownImageBuilder imageBuilder;
  final void Function(String?) onLink;
  @override
  State<MarkdownAnchorPreview> createState() => _MarkdownAnchorPreviewState();
}

class _MarkdownAnchorPreviewState extends State<MarkdownAnchorPreview>
    implements MarkdownBuilderDelegate {
  final _recognizers = <TapGestureRecognizer>[];
  void _clearRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onLink(href);
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
    style: styleSheet.code,
    text: code.replaceFirst(RegExp(r'\n$'), ''),
  );
  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      imageDirectory: null,
      imageBuilder: widget.imageBuilder,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: {
        'gemsnote-mermaid': MermaidElementBuilder(),
        'gemsnote-math': MathElementBuilder(),
        'gemsnote-math-block': MathElementBuilder(block: true),
      },
      paddingBuilders: {},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
      softLineBreak: true,
    );
    return MermaidScope(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: builder.build(widget.nodes),
        ),
      ),
    );
  }
}
