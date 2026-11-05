import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note_image_reference.dart';
import 'package:gemsnote/ui/markdown_note_body.dart';
import 'package:gemsnote/ui/cached_markdown_image.dart';

void main() {
  testWidgets(
    'download is explicit, duplicate taps blocked, failure can retry',
    (tester) async {
      var calls = 0;
      var pending = Completer<Uint8List>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedMarkdownImage(
              uri: Uri.parse('/image'),
              alt: 'photo',
              load: (_) async => null,
              download: () {
                calls++;
                return pending.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('下载图片'));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.textContaining('下载失败'), findsOneWidget);
      pending = Completer<Uint8List>();
      await tester.tap(find.text('下载图片'));
      await tester.pump();
      pending.complete(File('assets/images/gemsnote_s.png').readAsBytesSync());
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('下载失败'), findsNothing);
    },
  );
  testWidgets('external Markdown references never get download action', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownNoteBody(
            content: '![external](https://other.test/a.png)',
            loadCachedImage: (_) async => null,
            canDownloadImage: (_) => false,
            downloadImage: (_) async {
              calls++;
              return Uint8List(0);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('下载图片'), findsNothing);
    expect(calls, 0);
  });
  final server = Uri.parse('https://example.test');
  const id = '507f1f77bcf86cd799439011';
  test('only same-origin known stored image references yield IDs', () {
    for (final path in [
      '/api2/file/getImage',
      '/api/file/getImage',
      '/file/outputImage',
    ]) {
      expect(cachedImageFileId(Uri.parse('$path?fileId=$id'), server), id);
      expect(
        cachedImageFileId(
          Uri.parse('https://example.test$path?fileId=$id'),
          server,
        ),
        id,
      );
    }
    for (final value in [
      'https://evil.test/api2/file/getImage?fileId=$id',
      'http://example.test/api2/file/getImage?fileId=$id',
      'https://user:pwd@example.test/api2/file/getImage?fileId=$id',
      '/api2/file/getAttach?fileId=$id',
      'file:///private/image.png',
      'data:image/png;base64,AAAA',
      '/api2/file/getImage?fileId=$id&fileId=$id',
      '/api2/file/getImage?fileId=$id#anchor',
      '/api2/file/getImage?fileId=invalid',
      '/private/$id',
      'http:broken',
    ]) {
      expect(
        cachedImageFileId(Uri.parse(value), server),
        isNull,
        reason: value,
      );
    }
  });
  testWidgets(
    'Markdown uses supplied cache loader, without remote image providers',
    (tester) async {
      final requests = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownNoteBody(
              content: '![photo](/api2/file/getImage?fileId=$id)',
              loadCachedImage: (uri) async {
                requests.add(uri);
                return File('assets/images/gemsnote_s.png').readAsBytesSync();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests.single.queryParameters['fileId'], id);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).imageProvider, isA<MemoryImage>());
      expect(image.semanticLabel, 'photo');
      await tester.tap(find.byTooltip('查看图片'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('photo'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    },
  );
  for (final failure in ['missing', 'error', 'corrupt']) {
    testWidgets('cache $failure leaves readable placeholder', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownNoteBody(
              content: '![photo](/api2/file/getImage?fileId=$id)',
              loadCachedImage: (_) async {
                if (failure == 'error') throw StateError('unavailable');
                return failure == 'corrupt' ? Uint8List.fromList([0]) : null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('图片尚未缓存或无法读取：photo'), findsOneWidget);
    });
  }
}
