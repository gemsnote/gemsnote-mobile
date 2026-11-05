import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax()
    : super(
        r'\$\$([^$]+?)\$\$|\$(?![\s$])((?:\\.|[^$\n])*?(?:[^\s$\\]|\\.))\$(?![0-9])|\\\((.+?)\\\)|\\\[(.+?)\\\]',
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final body = match[1] ?? match[2] ?? match[3] ?? match[4]!;
    final raw = match[0]!;
    // Dollar-delimited inline formulas require non-whitespace edges, avoiding
    // ordinary prices such as "$5 and $10". Escapes/code are handled by Markdown.
    if (match[2] != null && body.trim() != body) {
      parser.addNode(md.Text(raw));
    } else {
      parser.addNode(
        md.Element.text('gemsnote-math', body)
          ..attributes['source'] = raw
          ..attributes['display'] = '${match[1] != null || match[4] != null}',
      );
    }
    return true;
  }
}

class MathBlockSyntax extends md.BlockSyntax {
  const MathBlockSyntax();
  @override
  RegExp get pattern => RegExp(r'^ {0,3}(\$\$|\\\[)(.*)$');
  ({int end, String body, String source})? _find(md.BlockParser parser) {
    final match = pattern.firstMatch(parser.current.content);
    if (match == null) return null;
    final close = match[1] == r'$$' ? r'$$' : r'\]';
    final body = <String>[];
    final raw = <String>[];
    var length = 0;
    for (var i = 0; i < 200; i++) {
      final line = parser.peek(i)?.content;
      if (line == null) return null;
      raw.add(line);
      final value = i == 0 ? match[2]! : line;
      length += value.length;
      if (length > 8192) return null;
      final end = value.indexOf(close);
      if (end >= 0) {
        if (value.substring(end + close.length).trim().isNotEmpty) return null;
        body.add(value.substring(0, end));
        return (end: i, body: body.join('\n').trim(), source: raw.join('\n'));
      }
      body.add(value);
    }
    return null;
  }

  @override
  bool canParse(md.BlockParser parser) => _find(parser) != null;
  @override
  md.Node parse(md.BlockParser parser) {
    final match = _find(parser)!;
    for (var i = 0; i <= match.end; i++) {
      parser.advance();
    }
    return md.Element.text('gemsnote-math-block', match.body)
      ..attributes['source'] = match.source;
  }
}

/// Bound parser/layout work and disallow commands unrelated to offline math.
/// Unsupported input is displayed verbatim; it is never rewritten or executed.
bool canRenderMath(String source) {
  if (source.isEmpty ||
      source.length > 2048 ||
      RegExp(
        r'\\(?:href|url|includegraphics|html\w*|input|include|require|def|gdef|edef|xdef|newcommand|renewcommand|let)\b',
      ).hasMatch(source) ||
      RegExp(r'\\[a-zA-Z]+|[_^{}]').allMatches(source).length > 256) {
    return false;
  }
  var depth = 0;
  var escaped = false;
  for (final rune in source.runes) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (rune == 92) {
      escaped = true;
      continue;
    }
    if (rune == 123 && ++depth > 32) return false;
    if (rune == 125 && --depth < 0) return false;
  }
  if (depth != 0) return false;
  for (final match in RegExp(
    r'(-?[0-9]+(?:\.[0-9]+)?)\s*(em|ex|mu|pt|px|cm|mm|in|pc|bp|dd|cc|sp)\b',
  ).allMatches(source)) {
    if ((double.tryParse(match[1]!) ?? double.infinity).abs() > 100) {
      return false;
    }
  }
  return true;
}

class MathElementBuilder extends MarkdownElementBuilder {
  MathElementBuilder({this.block = false});
  final bool block;
  @override
  bool isBlockElement() => block;
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final source = element.attributes['source'] ?? element.textContent;
    final expression = element.textContent;
    Widget fallback() =>
        SelectableText(source, style: preferredStyle ?? parentStyle);
    if (!canRenderMath(expression)) return fallback();
    final display = block || element.attributes['display'] == 'true';
    return Semantics(
      label: expression,
      child: Tooltip(
        message: source,
        child: GestureDetector(
          onLongPress: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(trNow(context, 'm0160')),
              content: SelectableText(source),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(trNow(context, 'm0010')),
                ),
              ],
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (MediaQuery.sizeOf(context).width - 40).clamp(
                80.0,
                1200.0,
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: display ? 8 : 0),
                child: Math.tex(
                  expression,
                  mathStyle: display ? MathStyle.display : MathStyle.text,
                  textStyle:
                      preferredStyle ??
                      parentStyle ??
                      const TextStyle(fontSize: 16),
                  settings: const TexParserSettings(
                    maxExpand: 128,
                    strict: Strict.ignore,
                  ),
                  onErrorFallback: (_) => fallback(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
