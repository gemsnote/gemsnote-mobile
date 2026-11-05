import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_editor_page.dart';

void main() {
  const src = '/api2/file/getImage?fileId=507f1f77bcf86cd799439011';
  for (final markdown in [true, false]) {
    final format = markdown ? 'Markdown' : '富文本';
    testWidgets(
      '$format editor preview reads cache without saving unchanged text',
      (tester) async {
        final content = markdown
            ? '![photo]($src)'
            : '<p>Text</p><img src="$src" alt="photo">';
        final reads = <Uri>[];
        var saves = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: NoteEditorPage(
              note: Note.fromJson({
                'NoteId': 'n',
                'Title': 'Title',
                'Content': content,
                'IsMarkdown': markdown,
              }),
              saveText: (_, _) async {
                saves++;
              },
              loadCachedImage: (uri) async {
                reads.add(uri);
                return File('assets/images/gemsnote_s.png').readAsBytesSync();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(reads, isEmpty);
        await tester.tap(
          find.byTooltip(markdown ? '预览 Markdown' : '预览富文本'),
        );
        await tester.pumpAndSettle();
        expect(reads, [Uri.parse(src)]);
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('下载图片'), findsNothing);
        expect(saves, 0);
        await tester.tap(find.byTooltip('继续编辑'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          content,
        );
        expect(saves, 0);
      },
    );

    testWidgets('$format missing or unreadable cache does not block editing', (
      tester,
    ) async {
      final content = markdown
          ? '![external](https://other.test/image)'
          : '<img src="file:///private" alt="external">';
      var fail = true;
      final saved = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditorPage(
            note: Note.fromJson({
              'Title': 'Title',
              'Content': content,
              'IsMarkdown': markdown,
            }),
            saveText: (_, body) async {
              saved.add(body);
            },
            loadCachedImage: (_) async {
              if (fail) throw StateError('cache unavailable');
              return null;
            },
          ),
        ),
      );
      final preview = markdown ? '预览 Markdown' : '预览富文本';
      await tester.tap(find.byTooltip(preview));
      await tester.pumpAndSettle();
      expect(find.textContaining('图片尚未缓存或无法读取'), findsOneWidget);
      expect(find.text('下载图片'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('继续编辑'));
      await tester.pumpAndSettle();
      fail = false;
      await tester.enterText(
        find.byType(TextField).last,
        '$content\nNew draft',
      );
      await tester.tap(find.byTooltip(preview));
      await tester.pumpAndSettle();
      expect(saved, ['$content\nNew draft']);
      expect(find.textContaining('图片尚未缓存或无法读取'), findsOneWidget);
      expect(find.text('下载图片'), findsNothing);
    });
  }
}
