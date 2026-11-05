import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'tag counts reflect live local notes, not stale synced tag records',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'user',
        server: Uri.parse('https://notes.example.test/'),
        username: 'admin',
        email: '',
        logo: '',
      );
      final note = Note.fromJson({
        'NoteId': 'one',
        'UserId': 'user',
        'Title': 'Local',
        'Usn': 1,
        'Tags': ['B', 'a', 'a', '', '  ', 'x,y', 'quoted"tag'],
      });
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [
          note,
          note.copyWith(noteId: 'trash', isTrash: true),
        ],
        tags: [
          {'Tag': 'unused', 'Usn': 1},
        ],
        lastSyncUsn: 1,
      );
      expect(await db.tagCounts(account.cacheKey), {
        'a': 1,
        'B': 1,
        'quoted"tag': 1,
        'x,y': 1,
      });
      expect((await db.tagCounts(account.cacheKey)).keys.toList(), [
        'a',
        'B',
        'quoted"tag',
        'x,y',
      ]);
      expect(await db.tagCounts('another-account'), isEmpty);
      expect(await db.notesForTag(account.cacheKey, ''), isEmpty);
      expect(await db.notesForTag(account.cacheKey, 'x'), isEmpty);
      expect(
        (await db.notesForTag(account.cacheKey, 'x,y')).single.noteId,
        'one',
      );
      await db.saveLocalNote(account.cacheKey, note.copyWith(tags: ['new']));
      expect(await db.tagCounts(account.cacheKey), {'new': 1});
      expect(await db.notesForTag(account.cacheKey, 'a'), isEmpty);
      await db.saveLocalNote(account.cacheKey, note.copyWith(isTrash: true));
      expect(await db.tagCounts(account.cacheKey), isEmpty);
    },
  );
}
