import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/markdown_note_body.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

// Synthetic notes only. Does not start the app session, use API2, or access user data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('offline native Mermaid rendering and zoom', (tester) async {
    const examples = [
      'flowchart LR\n A[记录想法] --> B[整理笔记]',
      'sequenceDiagram\n Alice->>Bob: Hello',
      'classDiagram\n Animal <|-- Duck',
      'stateDiagram-v2\n [*] --> Ready',
      'gantt\n title 计划\n dateFormat YYYY-MM-DD\n section 工作\n 实现 :2026-11-01, 2d',
    ];
    // Markdown lazily mounts off-screen blocks. Exercise each diagram visibly.
    for (final source in examples) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownNoteBody(content: '```mermaid\n$source\n```'),
          ),
        ),
      );
      for (var i = 0; i < 60 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('图表无法渲染，请检查语法或图表大小。'), findsNothing);
      expect(find.byType(Image), findsOneWidget, reason: source);
      expect(find.byType(WebViewWidget, skipOffstage: false), findsOneWidget);
      // Wait for native image decoding before interacting.
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Repeated source shares a renderer/cache but must not create duplicate keys.
    final repeated = List.filled(
      2,
      '```mermaid\nflowchart LR\nA-->B\n```',
    ).join('\n\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MarkdownNoteBody(content: repeated)),
      ),
    );
    for (var i = 0; i < 60 && find.byType(Image).evaluate().length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byType(WebViewWidget, skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownNoteBody(content: '```mermaid\nnot a diagram\n```'),
        ),
      ),
    );
    for (
      var i = 0;
      i < 60 && find.text('图表无法渲染，请检查语法或图表大小。').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('图表无法渲染，请检查语法或图表大小。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
