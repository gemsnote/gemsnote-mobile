import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/note_link_opener.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:gemsnote/ui/note_link_dialog.dart';

void main() {
  testWidgets(
    'HTML links are decoded, deduplicated and require explicit confirmation',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeHtmlNoteBody(
              content:
                  '<p><a href="https://example.test/?a=1&amp;b=2">Site</a></p>'
                  '<table><tr><td><a href="https://example.test/?a=1&amp;b=2">Again</a></td></tr></table>'
                  '<script><a href="https://hidden.test">Hidden</a></script>'
                  '<iframe><a href="https://hidden.test">Hidden</a></iframe>'
                  '<template><a href="https://hidden.test">Hidden</a></template>',
              linkOpener: NoteLinkOpener(
                launch: (uri, _) async {
                  calls++;
                  expect(uri.toString(), 'https://example.test/?a=1&b=2');
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      expect(calls, 0);
      expect(find.text('正文链接（1）'), findsOneWidget);
      await tester.ensureVisible(find.byType(ExpansionTile));
      await tester.tap(find.text('正文链接（1）'));
      await tester.pumpAndSettle();
      final link = find.widgetWithText(
        ListTile,
        'https://example.test/?a=1&b=2',
      );
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.byType(NoteLinkDialog), findsOneWidget);
      await tester.tap(find.text('外部打开'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(NoteLinkDialog), findsNothing);
    },
  );
  testWidgets('relative and unsafe HTML links remain view/copy only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeHtmlNoteBody(
            content: '<a href="javascript:alert(1)">Unsafe</a><a href="/relative">Relative</a>',
            linkOpener: NoteLinkOpener(
              launch: (_, _) async => throw TestFailure('must not launch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('正文链接（2）'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'javascript:alert(1)'));
    await tester.pumpAndSettle();
    expect(find.text('外部打开'), findsNothing);
    expect(find.text('复制链接'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteLinkDialog), findsNothing);
  });
  testWidgets(
    'HTML link list is bounded and text-only documents keep no link controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeHtmlNoteBody(
              content: List.generate(
                101,
                (i) => '<a href="https://example.test/$i">$i</a>',
              ).join(),
            ),
          ),
        ),
      );
      expect(find.text('正文链接（100）'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SafeHtmlNoteBody(content: '<p>Just text</p>')),
        ),
      );
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
    },
  );
}
