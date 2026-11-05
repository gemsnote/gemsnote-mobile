import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:archive/archive.dart';
import 'package:gemsnote/services/note_exporter.dart';
import 'package:gemsnote/ui/note_reader_page.dart';

void main() {
  Note note({
    bool md = true,
    String title = '珠玑笔记',
    String content = '原文\n正文',
  }) => Note.fromJson({
    'NoteId': 'n',
    'Title': title,
    'Content': content,
    'IsMarkdown': md,
  });
  for (final md in [true, false]) {
    test('exports Hugo Markdown from source: markdown=$md', () async {
      const content = '<script>example()</script>\n# **珠玑**\n';
      final exporter = NoteExporter(
        save: ({required fileName, required bytes, required mimeType}) async {
          expect(fileName, md ? '珠玑笔记.md' : '珠玑笔记.rtf');
          expect(
            utf8.decode(bytes),
            startsWith(md ? '---\ntitle:' : r'{\rtf1'),
          );
          if (md) expect(utf8.decode(bytes), endsWith(content));
          if (!md) expect(utf8.decode(bytes), isNot(contains('<script>')));
          expect(mimeType, md ? 'text/markdown' : 'application/rtf');
          return Uri.parse('content://provider/result');
        },
      );
      expect(await exporter.export(note(md: md, content: content)), isTrue);
    });
  }
  test('notebook exporter saves ZIP via native callback and propagates cancellation', () async {
    final book = Notebook.fromJson({'NotebookId': 'b', 'Title': 'Book'});
    for (final cancelled in [false, true]) {
      final exporter = NoteExporter(
        save: ({required fileName, required bytes, required mimeType}) async {
          expect(fileName, 'Book.zip');
          expect(mimeType, 'application/zip');
          final zip = ZipDecoder().decodeBytes(bytes);
          expect(zip.files.where((f) => f.isFile).length, 1);
          return cancelled ? null : Uri.parse('content://provider/zip');
        },
      );
      expect(
        await exporter.exportNotebook(
          book,
          [book],
          [note().copyWith(notebookId: 'b')],
        ),
        !cancelled,
      );
    }
  });
  test(
    'safe file names retain Unicode, remove separators and bound length',
    () {
      expect(NoteExporter.fileName(note(title: '../a/b\\c\n')), '_a_b_c_.md');
      expect(NoteExporter.fileName(note(title: '...')), '未命名笔记.md');
      expect(NoteExporter.fileName(note(title: 'Example.MD')), 'Example.md');
      expect(
        NoteExporter.fileName(note(title: List.filled(100, '😀').join()))
            .runes
            .length,
        53,
      );
    },
  );
  test('cancel is not success; errors are propagated', () async {
    expect(
      await NoteExporter(
        save: ({required fileName, required bytes, required mimeType}) async =>
            null,
      ).export(note()),
      isFalse,
    );
    await expectLater(
      NoteExporter(
        save: ({required fileName, required bytes, required mimeType}) async =>
            throw StateError('disk full'),
      ).export(note()),
      throwsStateError,
    );
  });
  for (final result in ['success', 'cancel', 'error']) {
    testWidgets('reader export $result stays open and reports correct result', (
      tester,
    ) async {
      final pending = Completer<bool>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: note(),
            onExport: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出笔记'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('正在导出…'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(item.enabled, isFalse);
      Navigator.of(tester.element(find.text('正在导出…'))).pop();
      await tester.pumpAndSettle();
      if (result == 'error') {
        pending.completeError(StateError('disk full'));
      } else {
        pending.complete(result == 'success');
      }
      await tester.pumpAndSettle();
      expect(find.byType(NoteReaderPage), findsOneWidget);
      expect(
        find.text('笔记已导出'),
        result == 'success' ? findsOneWidget : findsNothing,
      );
      expect(
        find.textContaining('导出失败'),
        result == 'error' ? findsOneWidget : findsNothing,
      );
    });
  }
}
