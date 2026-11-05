import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/conflict_copy.dart';
import 'package:gemsnote/ui/editor_link_dialog.dart';
import 'package:gemsnote/ui/visual_html_policy.dart';

void main() {
  test(
    'link policy rejects executable, local, relative and credential URLs',
    () {
      for (final value in [
        '',
        '/api2/file/x',
        '//host/a',
        'javascript:alert(1)',
        'data:text/html,a',
        'file:///private/x',
        'https://u:p@host/a',
        'https://',
        'https://host/a\nb',
        ' https://host',
        'https://host/a b',
      ]) {
        expect(isSafeEditorLink(value), isFalse, reason: value);
      }
      for (final value in [
        'https://example.com',
        'http://example.com:8080/a#b',
        'https://example.com/?q=%22%3Cscript%3E',
        'https://example.com/珠玑',
      ]) {
        expect(isSafeEditorLink(value), isTrue, reason: value);
      }
    },
  );

  test('visual link support does not broaden conflict copying', () {
    const source = '<a href="https://example.com/a">链接</a>';
    expect(supportsVisualHtml(source), isTrue);
    expect(canCopyConflictBody(source, isMarkdown: false), isFalse);
    for (final source in [
      '<a href="&#106;avascript:alert(1)">x</a>',
      '<a href="https://example.com" onclick="alert(1)">x</a>',
      '<p href="https://example.com">x</p>',
      '<a href="https://example.com" target="_blank">x</a>',
      '<a href="/api2/file/getImage?fileId=x">x</a>',
    ]) {
      expect(supportsVisualHtml(source), isFalse, reason: source);
    }
  });

  testWidgets('link dialog rejects unsafe URLs and returns trimmed URL', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const EditorLinkDialog(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'javascript:alert(1)');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorLinkDialog), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(find.byType(TextField), '  https://example.com/a  ');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, 'https://example.com/a');
    expect(find.byType(EditorLinkDialog), findsNothing);
  });

  testWidgets('cancel does not return a link', (tester) async {
    String? result = 'not closed';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const EditorLinkDialog(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
