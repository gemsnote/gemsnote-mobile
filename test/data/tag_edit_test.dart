import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  final note = Note.fromJson({
    'NoteId': 'n',
    'Title': 'latest',
    'Content': 'latest body',
    'Tags': ['one', 'two'],
    'NotebookId': 'book',
    'Usn': 7,
    'IsStar': true,
    'CreatedTime': '2025-01-01',
    'UpdatedTime': '2025-02-01',
  });
  late AppDatabase db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [note],
      tags: [],
      lastSyncUsn: 7,
    );
  });
  tearDown(() => db.raw.close());

  test(
    'tag patch normalizes, preserves body and sync metadata, updates counts',
    () async {
      await db.saveNoteTags(account.cacheKey, 'n', [
        ' two ',
        'three',
        'two',
        '',
      ]);
      final edited = (await db.dirtyNotes(account.cacheKey)).single;
      expect(edited.tags, ['two', 'three']);
      expect(edited.content, note.content);
      expect(edited.title, note.title);
      expect(edited.notebookId, note.notebookId);
      expect(edited.isStarred, isTrue);
      expect(edited.usn, 7);
      expect(edited.createdTime, note.createdTime);
      expect(await db.notesForTag(account.cacheKey, 'one'), isEmpty);
      expect(await db.notesForTag(account.cacheKey, 'three'), hasLength(1));
      expect(await db.lastSyncUsn(account.cacheKey), 7);
    },
  );
  test('unchanged tags neither dirty the note nor update time', () async {
    await db.saveNoteTags(account.cacheKey, 'n', ['one', 'two', 'one', ' ']);
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
    expect(
      (await db.notes(account.cacheKey)).single.updatedTime,
      note.updatedTime,
    );
  });
  test('empty tags are rejected without any partial modification', () async {
    await expectLater(
      db.saveNoteTags(account.cacheKey, 'n', [' ']),
      throwsFormatException,
    );
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
    expect((await db.notes(account.cacheKey)).single.tags, note.tags);
    final draft = await db.createLocalNote(
      account: account,
      notebookId: 'book',
      isMarkdown: true,
    );
    await db.saveNoteTags(account.cacheKey, draft.noteId, ['new']);
    await expectLater(
      db.saveNoteTags(account.cacheKey, draft.noteId, []),
      throwsFormatException,
    );
  });
  test('foreign, absent and deleted notes cannot be patched', () async {
    await expectLater(
      db.saveNoteTags('other-account', 'n', ['x']),
      throwsStateError,
    );
    await expectLater(
      db.saveNoteTags(account.cacheKey, 'missing', ['x']),
      throwsStateError,
    );
    await db.saveLocalNote(account.cacheKey, note.copyWith(isTrash: true));
    await db.deleteLocalTrash(account.cacheKey, 'n');
    await expectLater(
      db.saveNoteTags(account.cacheKey, 'n', ['x']),
      throwsStateError,
    );
  });
}
