import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/note_link_opener.dart';
import 'package:gemsnote/ui/markdown_note_body.dart';
import 'package:gemsnote/ui/note_link_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  test(
    'only complete web URLs without credentials qualify for external launch',
    () {
      for (final value in [
        'https://example.test/a?q=1#section',
        'http://localhost:8080/',
        'HTTPS://example.test/',
        'https://[::1]/',
      ]) {
        expect(externalNoteLink(value), isNotNull, reason: value);
      }
      for (final value in [
        '',
        '/api2/file/getImage?id=a',
        '//example.test/',
        'javascript:alert(1)',
        'data:text/html,hello',
        'file:///private/a',
        'intent://example',
        'mailto:a@example.test',
        'https://user:password@example.test/',
        'https://@example.test/',
        ' https://example.test',
        'https://example.test/\npath',
        r'https://example.test\@evil.test',
        'https://example.test/\u202eevil',
        'https://example.test:70000/',
        'https://',
        'https://example.test/${'a' * 8192}',
      ]) {
        expect(externalNoteLink(value), isNull, reason: value);
      }
    },
  );
  test('launch receives only the URL and externalApplication mode', () async {
    var calls = 0;
    final opener = NoteLinkOpener(
      launch: (uri, mode) async {
        calls++;
        expect(uri.toString(), 'https://example.test/a?q=1#section');
        expect(mode, LaunchMode.externalApplication);
        return true;
      },
    );
    await opener.open('https://example.test/a?q=1#section');
    await expectLater(
      opener.open('javascript:alert(1)'),
      throwsFormatException,
    );
    expect(calls, 1);
  });
  test('native refusal is a retryable failure', () async {
    await expectLater(
      NoteLinkOpener(launch: (_, _) async => false)
          .open('https://example.test'),
      throwsStateError,
    );
  });

  Future<void> mount(WidgetTester tester, NoteLinkOpener opener) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownNoteBody(
            content: '[Example](https://example.test/path)',
            linkOpener: opener,
          ),
        ),
      ),
    );
  }

  void tapLink(
    WidgetTester tester, [
    String href = 'https://example.test/path',
  ]) {
    tester.widget<Markdown>(find.byType(Markdown)).onTapLink!(
      'Example',
      href,
      '',
    );
  }

  testWidgets(
    'render and link tap never launch; confirm blocks duplicates and closes on acceptance',
    (tester) async {
      var calls = 0;
      final pending = Completer<bool>();
      await mount(
        tester,
        NoteLinkOpener(
          launch: (_, _) {
            calls++;
            return pending.future;
          },
        ),
      );
      expect(calls, 0);
      tapLink(tester);
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('https://example.test/path'), findsOneWidget);
      expect(find.text('目标网站：example.test'), findsOneWidget);
      await tester.tap(find.text('外部打开'));
      await tester.pump();
      await tester.tap(find.text('外部打开'));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(NoteLinkDialog), findsNothing);
    },
  );
  for (final throwsError in [false, true]) {
    testWidgets(
      'native failure throws=$throwsError keeps address and supports retry',
      (tester) async {
        var calls = 0;
        await mount(
          tester,
          NoteLinkOpener(
            launch: (_, _) async {
              calls++;
              if (calls == 1) {
                if (throwsError) throw StateError('no handler');
                return false;
              }
              return true;
            },
          ),
        );
        tapLink(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('外部打开'));
        await tester.pumpAndSettle();
        expect(find.text('无法打开链接，请重试或复制地址到浏览器'), findsOneWidget);
        expect(find.text('复制链接'), findsOneWidget);
        await tester.tap(find.text('外部打开'));
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(find.byType(NoteLinkDialog), findsNothing);
      },
    );
  }
  testWidgets('unsupported addresses stay copy-only; closing does not launch', (
    tester,
  ) async {
    var calls = 0;
    await mount(
      tester,
      NoteLinkOpener(
        launch: (_, _) async {
          calls++;
          return true;
        },
      ),
    );
    tapLink(tester, 'file:///private/file');
    await tester.pumpAndSettle();
    expect(find.text('外部打开'), findsNothing);
    expect(find.text('复制链接'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    tapLink(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });
}
