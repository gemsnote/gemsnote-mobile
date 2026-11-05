import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gemsnote/ui/markdown_math.dart';
import 'package:gemsnote/ui/markdown_editing.dart';
import 'package:gemsnote/ui/markdown_note_body.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  List<md.Node> parse(String text) => md.Document(
    inlineSyntaxes: [MathInlineSyntax()],
    blockSyntaxes: [const MathBlockSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(text.split('\n'));
  List<md.Element> formulas(List<md.Node> nodes) {
    final result = <md.Element>[];
    void visit(md.Node node) {
      if (node is md.Element) {
        if (node.tag.startsWith('gemsnote-math')) result.add(node);
        for (final child in node.children ?? <md.Node>[]) {
          visit(child);
        }
      }
    }

    for (final node in nodes) {
      visit(node);
    }
    return result;
  }

  test('dollar and bracket delimiters preserve TeX including comparison characters', () {
    final values = formulas(
      parse(r'Inline $x<y$ and \(\frac{a}{b}\), display $$a^2$$ and \[b^2\].'),
    );
    expect(values.map((n) => n.textContent), [
      r'x<y',
      r'\frac{a}{b}',
      'a^2',
      'b^2',
    ]);
    expect(values.first.attributes['source'], r'$x<y$');
    expect(formulas(parse(r'$$a$$ and $$b$$')).map((n) => n.textContent), [
      'a',
      'b',
    ]);
    final blocks = formulas(
      parse('Before\n\n\$\$\na^2 + b^2\n= c^2\n\$\$\n\nAfter'),
    );
    expect(blocks.single.tag, 'gemsnote-math-block');
    expect(blocks.single.textContent, 'a^2 + b^2\n= c^2');
    expect(formulas(parse('\\[\nx+y\n\\]')).single.textContent, 'x+y');
  });
  test('escaped dollars, currency and code remain literal; unterminated blocks lose no prose', () {
    for (final source in [
      r'\$x\$',
      r'`$x$`',
      '```tex\n\$x\$\n```',
      r'Cost $5 and $10',
      r'$$ not closed',
    ]) {
      expect(formulas(parse(source)), isEmpty, reason: source);
    }
    final source = '\$\$\nno closing fence\n\n# Following heading';
    final nodes = parse(source);
    expect(
      nodes.map((n) => n.textContent).join(),
      contains('Following heading'),
    );
    expect(
      formulas(parse(r'Cost $5 and $10, then $x$.')).single.textContent,
      'x',
    );
  });
  test('rendering bounds reject macros, external commands and excessive dimensions', () {
    expect(canRenderMath(r'\frac{1}{2}+\sqrt{x_1^2}'), isTrue);
    for (final source in [
      r'\href{https://x}{x}',
      r'\includegraphics{x}',
      r'\def\x{\x}\x',
      r'\kern1000000em',
      "${List.filled(33, '{').join()}x${List.filled(33, '}').join()}",
      List.filled(2049, 'x').join(),
    ]) {
      expect(canRenderMath(source), isFalse);
    }
  });
  testWidgets(
    'formulas render offline; parse failures retain their exact source',
    (tester) async {
      const source = r'Math $\frac{1}{2}$ and $\unsupportedcommand{x}$.';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MarkdownNoteBody(content: source)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsNWidgets(2));
      expect(find.text(r'$\unsupportedcommand{x}$'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.longPress(find.byType(Math).first);
      await tester.pumpAndSettle();
      expect(find.text('公式原文'), findsOneWidget);
      expect(find.text(r'$\frac{1}{2}$'), findsOneWidget);
    },
  );
  testWidgets('oversized formulas fall back without building the TeX parser', (
    tester,
  ) async {
    final source = '\$${List.filled(3000, 'x').join()}\$';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MarkdownNoteBody(content: source)),
      ),
    );
    expect(find.byType(Math), findsNothing);
    expect(find.text(source), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('table and rule insertions retain selected prose; math wraps it with editable selection', () {
    const value = TextEditingValue(
      text: 'before x after',
      selection: TextSelection(baseOffset: 7, extentOffset: 8),
    );
    final table = insertMarkdownTable(value);
    expect(table.text, startsWith('before x\n\n|'));
    expect(table.text, endsWith('\n\n after'));
    expect(insertMarkdownBlock(value, '---').text, 'before x\n\n---\n\n after');
    final math = fenceMarkdownMath(value);
    expect(math.text, 'before \n\n\$\$\nx\n\$\$\n\n after');
    expect(math.selection.textInside(math.text), 'x');
    expect(fenceMarkdownMath(const TextEditingValue()).text, '\$\$\n\n\$\$\n');
  });
}
