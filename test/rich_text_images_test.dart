import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/cached_markdown_image.dart';
import 'package:gemsnote/ui/note_reader_page.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  const src = '/api2/file/getImage?fileId=507f1f77bcf86cd799439011';
  testWidgets(
    'images retain nested document order with selectable text on a small screen',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: SafeHtmlNoteBody(
                content:
                    '<p>Before<strong><img src="$src" alt="first">Middle</strong>'
                    '<img src="$src" alt="second">After</p>',
                loadCachedImage: (_) async =>
                    File('assets/images/gemsnote_s.png').readAsBytesSync(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bodyText = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.textSpan?.toPlainText().contains('Before') == true,
        ),
      );
      expect(
        bodyText.textSpan!.toPlainText(),
        '\nBefore\n\uFFFC\nMiddle\n\uFFFC\nAfter\n',
      );
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.textContaining('正文图片（'), findsNothing);
      final images = find.byType(CachedMarkdownImage);
      expect(images, findsNWidgets(2));
      expect(
        tester.getTopLeft(images.first).dy,
        lessThan(tester.getTopLeft(images.last).dy),
      );
      expect(tester.getSize(images.first).width, lessThanOrEqualTo(240));
      expect(find.text('下载图片'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'personal rich reader defaults to native preview and manual image download',
    (tester) async {
      var downloads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: Note.fromJson({
              'NoteId': 'n',
              'Title': 'RT',
              'IsMarkdown': false,
              'Content': '<p>Hello</p><img src="$src" alt="photo">',
            }),
            loadCachedImage: (_) async => null,
            canDownloadImage: (uri) => uri.toString() == src,
            downloadImage: (_) async {
              downloads++;
              return File('assets/images/gemsnote_s.png').readAsBytesSync();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.byType(SafeHtmlNoteBody), findsOneWidget);
      expect(downloads, 0);
      await tester.tap(find.text('下载图片'));
      await tester.pumpAndSettle();
      expect(downloads, 1);
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byTooltip('查看原文'));
      await tester.pumpAndSettle();
      expect(find.byType(CachedMarkdownImage), findsNothing);
      expect(find.textContaining('<img src='), findsOneWidget);
    },
  );
  testWidgets(
    'cached images load offline; active wrappers and external references cannot download',
    (tester) async {
      final loaded = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeHtmlNoteBody(
              content:
                  '<iframe><img src="hidden"></iframe><script>bad()</script><img src="$src"><img src="https://other.test/x"><img src="file:///private">',
              loadCachedImage: (uri) async {
                loaded.add(uri.toString());
                return uri.toString() == src
                    ? File('assets/images/gemsnote_s.png').readAsBytesSync()
                    : null;
              },
              canDownloadImage: (_) => false,
              downloadImage: (_) async => throw StateError('must not download'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loaded, [src, 'https://other.test/x', 'file:///private']);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('下载图片'), findsNothing);
      expect(find.byType(WebViewWidget), findsNothing);
    },
  );
  testWidgets('image callbacks are optional and collection is bounded', (
    tester,
  ) async {
    final content = List.filled(105, '<img src="$src">').join();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SafeHtmlNoteBody(content: content)),
      ),
    );
    expect(find.byType(CachedMarkdownImage), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeHtmlNoteBody(
            content: content,
            loadCachedImage: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CachedMarkdownImage), findsNWidgets(100));
  });
}
