import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/services/note_importer.dart';
import 'package:gemsnote/ui/import_note_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class PickedSource extends PlatformFile {
  PickedSource(this.name, this.bytes, {this.reportedSize});
  @override
  final String name;
  final Uint8List bytes;
  final int? reportedSize;
  bool read = false;
  @override
  Uri get uri => Uri.parse('content://test/source');
  @override
  Never get xFile => throw UnsupportedError('unused');
  @override
  int? lengthSync() => reportedSize;
  @override
  Future<int?> length() async => reportedSize;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() async* {
    read = true;
    yield bytes;
  }
}

void main() {
  NoteImporter source(String name, String body) => NoteImporter(
    pick: () async => PickedSource(name, Uint8List.fromList(utf8.encode(body))),
  );
  test('cancel picker without creating a note', () async {
    expect(await NoteImporter(pick: () async => null).pick(), isNull);
  });
  test('preserve UTF8 body and normalize title and BOM', () async {
    final note = (await source(r'folder\珠玑.MD', '\ufeff# 内容\n').pick())!;
    expect(note.title, '珠玑');
    expect(note.content, '# 内容\n');
    expect(note.isMarkdown, isTrue);
    expect((await source('.txt', '').pick())!.title, '导入的笔记');
  });
  test('HTML remains unchanged source and TXT uses Markdown', () async {
    const html = '<script>alert(1)</script><p>Hello</p>';
    final note = (await source('note.HTML', html).pick())!;
    expect(note.content, html);
    expect(note.isMarkdown, isFalse);
    expect((await source('note.txt', 'text').pick())!.isMarkdown, isTrue);
  });
  test('reject unsupported extensions, binary and malformed UTF8', () async {
    await expectLater(source('note.exe', 'text').pick(), throwsFormatException);
    await expectLater(
      source('note.md', '\u0000').pick(),
      throwsFormatException,
    );
    await expectLater(
      NoteImporter(
        pick: () async => PickedSource('note.md', Uint8List.fromList([255])),
      ).pick(),
      throwsFormatException,
    );
  });
  test('enforce declared and actual byte limits', () async {
    final file = PickedSource(
      'note.md',
      Uint8List(0),
      reportedSize: NoteImporter.maxBytes + 1,
    );
    await expectLater(
      NoteImporter(pick: () async => file).pick(),
      throwsStateError,
    );
    expect(file.read, isFalse);
    final oversized = PickedSource(
      'note.md',
      Uint8List(NoteImporter.maxBytes + 1),
      reportedSize: 1,
    );
    await expectLater(
      NoteImporter(pick: () async => oversized).pick(),
      throwsStateError,
    );
  });
  test(
    'import persists complete source as an account scoped new dirty note',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'user',
        server: Uri.parse('https://example.test'),
        username: 'name',
        email: '',
        logo: '',
      );
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 0,
      );
      final imported = (await source('original.md', '# 原文').pick())!;
      final note = await db.createLocalNote(
        account: account,
        notebookId: 'book',
        isMarkdown: imported.isMarkdown,
        title: imported.title,
        content: imported.content,
      );
      final dirty = (await db.dirtyNotes(account.cacheKey)).single;
      expect(dirty.noteId, note.noteId);
      expect(dirty.title, 'original');
      expect(dirty.content, '# 原文');
      expect(dirty.notebookId, 'book');
      expect(dirty.usn, 0);
      expect(await db.dirtyNotes('another-account'), isEmpty);
      final rows = await db.raw.query('notes');
      expect(rows.single['local_is_new'], 1);
    },
  );
  testWidgets(
    'selection does not write until confirmed; failure stays retryable',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImportNoteDialog(
              targetTitle: 'Destination',
              importer: source('note.md', '# body'),
              onImport: (_) async {
                attempts++;
                throw StateError('disk full');
              },
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('选择文件'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(attempts, 0);
      expect(find.text('导入到：Destination'), findsOneWidget);
      expect(find.text('note'), findsOneWidget);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(find.textContaining('存储空间不足'), findsOneWidget);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
    },
  );
}
