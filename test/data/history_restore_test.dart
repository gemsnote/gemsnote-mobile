import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'history restore patches body while preserving latest metadata and USN',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'user',
        server: Uri.parse('https://example.test/'),
        username: 'User',
        email: '',
        logo: '',
      );
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 7,
      );
      final draft = await db.createLocalNote(
        account: account,
        notebookId: 'book',
        isMarkdown: true,
      );
      final updated = draft.copyWith(
        title: 'Latest title',
        notebookId: 'moved-book',
        tags: ['current-tag'],
        isStarred: true,
        usn: 12,
        content: 'Current body',
      );
      await db.saveLocalNote(account.cacheKey, updated);
      await db.markNoteUploaded(account.cacheKey, updated, updated);
      await db.restoreHistoryContent(
        account.cacheKey,
        draft.noteId,
        'Historic body',
      );
      final restored = (await db.dirtyNotes(account.cacheKey)).single;
      expect(restored.content, 'Historic body');
      expect(restored.title, 'Latest title');
      expect(restored.notebookId, 'moved-book');
      expect(restored.tags, ['current-tag']);
      expect(restored.isStarred, true);
      expect(restored.usn, 12);
      expect(restored.createdTime, draft.createdTime);
      expect(await db.lastSyncUsn(account.cacheKey), 7);
      await db.restoreHistoryContent(account.cacheKey, draft.noteId, '');
      expect((await db.dirtyNotes(account.cacheKey)).single.content, '');
      await expectLater(
        db.restoreHistoryContent('another-account', draft.noteId, 'bad'),
        throwsStateError,
      );
      expect((await db.dirtyNotes(account.cacheKey)).single.content, '');
      await expectLater(
        db.restoreHistoryContent(account.cacheKey, 'deleted-note', 'bad'),
        throwsStateError,
      );
    },
  );
}
