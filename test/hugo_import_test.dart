import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/services/hugo_export.dart';
import 'package:gemsnote/services/hugo_import.dart';
import 'package:gemsnote/services/note_importer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_import_test.dart' show PickedSource;

void main() {
  final original = Note.fromJson({
    'NoteId': 'note',
    'NotebookId': 'book',
    'UserId': 'user',
    'Title': '元数据 "标题"',
    'Tags': ['Go', '中文'],
    'CreatedTime': '2020-01-02T03:04:05+08:00',
    'UpdatedTime': '2021-02-03T04:05:06Z',
    'IsMarkdown': true,
    'Content': '# Body\r\n\r\n---\r\nkeep\r\n',
  });
  final headers = [
    '---\ntitle: \'元数据 "标题"\'\ndate: 2020-01-02T03:04:05+08:00\nlastmod: 2021-02-03T04:05:06Z\ntags:\n  - Go\n  - 中文\nparams:\n  other: ignored\n---\n',
    '+++\ntitle = \'元数据 "标题"\'\ndate = 2020-01-02T03:04:05+08:00\nlastmod = 2021-02-03T04:05:06Z\ntags = ["Go", "中文"]\n[params]\nother = "ignored"\n+++\n',
    '${jsonEncode({
      'title': original.title,
      'date': original.createdTime,
      'lastmod': original.updatedTime,
      'tags': original.tags,
      'params': {'other': '{ignored}'},
    })}\n',
  ];
  for (var i = 0; i < headers.length; i++) {
    test('reads Hugo format $i and strips the entire header', () async {
      final content = '${headers[i]}\n${original.content}';
      final result = (await NoteImporter(
        pick: () async => PickedSource(
          'filename.md',
          Uint8List.fromList(utf8.encode(content)),
        ),
      ).pick())!;
      expect(result.title, original.title);
      expect(result.tags, original.tags);
      expect(result.content, original.content);
      expect(result.createdTime, '2020-01-01T19:04:05.000Z');
      expect(result.updatedTime, '2021-02-03T04:05:06.000Z');
    });
  }
  test('round trips the application Hugo export', () {
    final parsed = parseHugoMarkdown(
      hugoMarkdown(original, 'Book'),
      'filename',
    );
    expect(parsed.title, original.title);
    expect(parsed.tags, original.tags);
    expect(parsed.content, original.content);
  });
  test('plain MD retains its filename and has no supplied times or tags', () {
    final parsed = parseHugoMarkdown('# Plain\n', 'filename');
    expect(parsed.title, 'filename');
    expect(parsed.content, '# Plain\n');
    expect(parsed.tags, isEmpty);
    expect(parsed.createdTime, isNull);
    expect(parsed.updatedTime, isNull);
  });
  test(
    'ZIP uses directory structure and validates all notes before writing',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('root.md', hugoMarkdown(original, 'Book')))
        ..addFile(
          ArchiveFile.string(
            'Dir/nested.md',
            hugoMarkdown(original.copyWith(title: 'Nested'), 'Dir'),
          ),
        )
        ..addFile(ArchiveFile.directory('Empty/'));
      final source = parseMarkdownArchive((
        name: 'archive.zip',
        bytes: ZipEncoder().encodeBytes(archive),
      ));
      expect(source.folders, ['Dir', 'Empty']);
      expect(source.notes.first.note.title, original.title);
      expect(source.notes.first.note.content, original.content);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'user',
        server: Uri.parse('https://example.test'),
        username: 'u',
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
      await db.raw.insert('notebooks', {
        'account_id': account.cacheKey,
        'server_id': 'target',
        'title': 'Target',
      });
      await db.importMarkdownArchive(
        account: account,
        notebookId: 'target',
        title: source.title,
        folders: source.folders,
        notes: source.notes
            .map(
              (entry) => (
                folder: entry.folder,
                title: entry.note.title,
                content: entry.note.content,
                tags: entry.note.tags,
                createdTime: entry.note.createdTime,
                updatedTime: entry.note.updatedTime,
              ),
            )
            .toList(),
      );
      final books = await db.raw.query('notebooks');
      expect(
        books.map((b) => b['title']),
        containsAll(['Target', 'Dir', 'Empty']),
      );
      expect(books.length, 3);
      final notes = await db.dirtyNotes(account.cacheKey);
      expect(notes.length, 2);
      final root = notes.singleWhere((n) => n.title == original.title);
      expect(root.notebookId, 'target');
      expect(root.tags, original.tags);
      expect(root.content, original.content);
      expect(root.createdTime, '2020-01-01T19:04:05.000Z');
      expect(root.updatedTime, '2021-02-03T04:05:06.000Z');
      archive.addFile(ArchiveFile.string('../unsafe.md', 'bad'));
      expect(
        () => parseMarkdownArchive((
          name: 'bad.zip',
          bytes: ZipEncoder().encodeBytes(archive),
        )),
        throwsFormatException,
      );
    },
  );
}
