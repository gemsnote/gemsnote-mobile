import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/markdown_anchor_preview.dart';
import 'package:gemsnote/ui/markdown_note_body.dart';
import 'package:gemsnote/ui/note_link_dialog.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  String render(String source) => md.markdownToHtml(
    source,
    blockSyntaxes: noteMarkdownBlocks,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  test('legacy header and code attributes preserve IDs, classes and code', () {
    final html = render(
      '# Title ## {#title.red .wide}\n\nSetext {#under}\n---\n\n```dart {#sample .numbered}\n# untouched {#literal}\n```\n\n``` {#plain}\ncode\n```',
    );
    expect(html, contains('<h1 id="title" class="red wide">Title</h1>'));
    expect(html, contains('<h2 id="under">Setext</h2>'));
    expect(
      html,
      contains(
        '<pre id="sample" class="numbered"><code class="language-dart">',
      ),
    );
    expect(html, contains('# untouched {#literal}'));
    expect(html, contains('<pre id="plain"><code>code'));
    for (final source in [
      '# Title {onclick=bad}',
      r'# Title \{#literal}',
      'Paragraph {#literal}',
      '`# code {#literal}`',
    ]) {
      expect(render(source), isNot(contains('id="literal"')));
      expect(render(source), isNot(contains('onclick="')));
    }
  });
  test('anchors resolve footnotes and heading sections in the same document', () {
    const source =
        '[jump](#target) and note[^a]\n\n# Target {#target}\nbody\n\n## Child\ninside\n\n# Next\noutside\n\n[^a]: **Footnote** with [reference][ref]\n\n[ref]: https://example.test';
    final section = md.renderToHtml(markdownAnchor(source, '#target')!);
    expect(section, contains('body'));
    expect(section, contains('inside'));
    expect(section, isNot(contains('outside')));
    final footnote = md.renderToHtml(markdownAnchor(source, '#fn-a')!);
    expect(footnote, contains('<strong>Footnote</strong>'));
    expect(footnote, contains('href="https://example.test"'));
    expect(markdownAnchor(source, '#missing'), isNull);
    expect(markdownAnchor(source, '#%broken'), isNull);
    expect(markdownAnchor(source, 'https://other.test/#target'), isNull);
  });
  testWidgets(
    'footnote and heading links expand locally and return to the reader',
    (tester) async {
      const source =
          '[Details](#target)\n\n[^a]\n\n# Target {#target}\nTarget body\n\n[^a]: Footnote explanation with [Website](https://example.test).';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MarkdownNoteBody(content: source)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownAnchorPreview), findsOneWidget);
      expect(find.byType(NoteLinkDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Target body'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(find.text('脚注'), findsOneWidget);
      expect(find.byType(MarkdownAnchorPreview), findsOneWidget);
      expect(find.byType(NoteLinkDialog), findsNothing);
    },
  );
}
