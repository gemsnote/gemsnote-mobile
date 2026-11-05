import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('text save skips no-op, preserves metadata, rejects missing or foreign note', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    addTearDown(db.raw.close);
    final account = Account(
      userId: 'u',
      server: Uri.parse('https://notes.example.test/'),
      username: 'user',
      email: '',
      logo: '',
    );
    final note = Note.fromJson({
      'NoteId': 'n',
      'Title': 'Title',
      'Content': 'Body',
      'NotebookId': 'book',
      'Usn': 7,
      'Tags': ['tag'],
      'IsStar': true,
      'UpdatedTime': '2026-01-01T00:00:00Z',
    });
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [note],
      tags: [],
      lastSyncUsn: 7,
    );
    await db.saveEditedText(account.cacheKey, 'n', 'Title', 'Body');
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
    expect(
      (await db.notes(account.cacheKey)).single.updatedTime,
      note.updatedTime,
    );
    await db.saveEditedText(account.cacheKey, 'n', 'New', 'New body');
    final changed = (await db.notes(account.cacheKey)).single;
    expect(changed.title, 'New');
    expect(changed.content, 'New body');
    expect(changed.usn, 7);
    expect(changed.notebookId, 'book');
    expect(changed.tags, ['tag']);
    expect(changed.isStarred, isTrue);
    expect(await db.pendingNoteIds(account.cacheKey), {'n'});
    // A later autosave must use the latest USN/metadata, not its editor snapshot.
    await db.markNoteUploaded(
      account.cacheKey,
      changed,
      changed.copyWith(usn: 8),
    );
    await db.mergeChanges(
      account: account,
      notebooks: [],
      notes: [
        changed.copyWith(
          usn: 9,
          notebookId: 'moved',
          tags: ['new-tag'],
          isStarred: false,
        ),
      ],
      tags: [],
      lastSyncUsn: 9,
    );
    await db.saveEditedText(account.cacheKey, 'n', 'New', 'Further edit');
    final latest = (await db.notes(account.cacheKey)).single;
    expect(latest.usn, 9);
    expect(latest.notebookId, 'moved');
    expect(latest.tags, ['new-tag']);
    expect(latest.isStarred, isFalse);
    await expectLater(
      db.saveEditedText('other-account', 'n', '', ''),
      throwsStateError,
    );
    await expectLater(
      db.saveEditedText(account.cacheKey, 'missing', '', ''),
      throwsStateError,
    );
  });
}
