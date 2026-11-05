import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/cached_markdown_image.dart';
import 'package:gemsnote/ui/markdown_definition_list.dart';
import 'package:gemsnote/ui/markdown_note_body.dart';
import 'package:gemsnote/ui/note_link_dialog.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  String render(String source) => md.markdownToHtml(
    source,
    blockSyntaxes: const [DefinitionListSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );

  test(
    'definition lists support several terms, definitions and nested blocks',
    () {
      final html = render(
        'Term\nAlias\n\n: **first**\n: second\n\n    - nested\n\nNext\n: last\n\nAfter',
      );
      expect(html, contains('<strong>Term</strong>'));
      expect(html, contains('<strong>Alias</strong>'));
      expect(html, contains('<strong>first</strong>'));
      expect(html, contains('<li>nested</li>'));
      expect(html, contains('<strong>Next</strong>'));
      expect(html, contains('<p>After</p>'));
      expect(RegExp('<blockquote>').allMatches(html), hasLength(3));
    },
  );

  test(
    'code, headings, tables, references and ordinary colons keep their meaning',
    () {
      for (final source in [
        '```\nTerm\n: definition\n```',
        '    Term\n    : definition',
        '# Heading\n: ordinary',
        'a | b\n--- | ---\n: ordinary | value',
        '[ref]: https://example.test\n: ordinary',
        'Ordinary: text',
        ': no term',
      ]) {
        expect(render(source), isNot(contains('<section>')), reason: source);
      }
    },
  );

  testWidgets(
    'definitions preserve line breaks and use safe image/link handlers',
    (tester) async {
      const source =
          'Term\n: first line\nsecond line\n\n    [Example](https://example.test)\n\n    ![photo](/api2/file/getImage?fileId=507f1f77bcf86cd799439011)';
      final reads = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownNoteBody(
              content: source,
              loadCachedImage: (uri) async {
                reads.add(uri);
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Term'), findsOneWidget);
      expect(find.text('first line\nsecond line'), findsOneWidget);
      expect(find.byType(CachedMarkdownImage), findsOneWidget);
      expect(reads.single.path, '/api2/file/getImage');
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.text('Example'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteLinkDialog), findsOneWidget);
    },
  );
}
