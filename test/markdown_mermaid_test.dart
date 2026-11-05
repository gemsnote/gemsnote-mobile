import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/markdown_anchor_preview.dart';
import 'package:gemsnote/ui/markdown_mermaid.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  List<md.Node> parse(String source) => md.Document(
    blockSyntaxes: noteMarkdownBlocks,
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.split('\n'));

  test(
    'only mermaid fences become diagrams; nested fences and attributes work',
    () {
      final nodes = parse(
        '```mermaid {#diagram}\nflowchart LR\n A[中文] --> B\n```\n\n```js\nx<y\n```',
      );
      expect((nodes[0] as md.Element).tag, 'gemsnote-mermaid');
      expect((nodes[0] as md.Element).attributes['id'], 'diagram');
      expect(nodes[0].textContent, contains('A[中文] --> B'));
      expect((nodes[1] as md.Element).tag, 'pre');
      final quoted = parse('> ~~~mermaid\n> flowchart LR\n> A-->B\n> ~~~');
      expect(
        ((quoted.single as md.Element).children!.single as md.Element).tag,
        'gemsnote-mermaid',
      );
      final ordinary = parse('````text\n```mermaid\nA-->B\n```\n````');
      expect((ordinary.single as md.Element).tag, 'pre');
      expect(
        markdownAnchor(
          '```mermaid {#diagram}\nflowchart LR\nA-->B\n```',
          '#diagram',
        )!.single,
        isA<md.Element>(),
      );
    },
  );
  test(
    'limits and unsafe configuration fail closed without changing source',
    () {
      expect(canRenderMermaid('flowchart LR\nA-->B'), isTrue);
      for (final source in [
        '',
        'x' * 20001,
        List.filled(501, 'x').join('\n'),
        '%%{init:{securityLevel:"loose"}}%%\nflowchart LR\nA-->B',
        '---\nconfig:\n securityLevel: loose\n---\nflowchart LR\nA-->B',
      ]) {
        expect(canRenderMermaid(source), isFalse);
      }
    },
  );
  testWidgets('renders cached image, enlarges and keeps copyable source', (
    tester,
  ) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAYAAABw4pVUAAAA+UlEQVR4nO3RoQ3AABDEsB+9m7e4E+SAgXmk3D33MiQPwJBpeQCGTMsDMGRaHoAh0/IADJmWB2DItDwAQ6blARgyLQ/AkGl5AIZMywMwZFoegCHT8gAMmZYHYMi0PABDpuUBGDItD8CQaXkAhkzLAzBkWh6AIdPyAAyZlgdgyLQ8AEOm5QEYMi0PwJBpeQCGTMsDMGRaHoAh0/IADJmWB2DItDwAQ6blARgyLQ/AkGl5AIZMywMwZFoegCHT8gAMmZYHYMi0PABDpuUBGDItD8CQaXkAhkzLAzBkWh6AIdPyAAyZlgdgyLQ8AEOm5QEYMi0PwJBpeQA/H43vdFf+vhWgAAAAAElFTkSuQmCC',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MermaidScope(
            renderOverride: (_) async => png,
            child: const MermaidDiagram(source: 'flowchart LR\nA-->B'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(png),
        tester.element(find.byType(MermaidDiagram)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('图表源码'));
    await tester.pumpAndSettle();
    expect(find.text('flowchart LR\nA-->B'), findsOneWidget);
  });
  testWidgets('failed render shows local error and preserves surrounding UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MermaidScope(
            renderOverride: (_) => Future.error(StateError('invalid')),
            child: const MermaidDiagram(source: 'not a diagram'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('图表无法渲染，请检查语法或图表大小。'), findsOneWidget);
    expect(find.text('not a diagram'), findsOneWidget);
  });
}
