import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';

void main() {
  test(
    'remote notebook deletion detaches trash without losing its body',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'u',
        server: Uri.parse('https://example.test'),
        username: 'u',
        email: '',
        logo: '',
      );
      final note = Note.fromJson({
        'NoteId': 'n',
        'NotebookId': 'b',
        'Title': 'Note',
        'Content': 'preserved',
        'Usn': 1,
      });
      await db.replaceSnapshot(
        account: account,
        notebooks: [
          Notebook.fromJson({'NotebookId': 'b', 'Title': 'Book'}),
        ],
        notes: [note],
        tags: [],
        lastSyncUsn: 1,
      );
      await db.mergeChanges(
        account: account,
        notebooks: [
          Notebook.fromJson({'NotebookId': 'b', 'IsDeleted': true}),
        ],
        notes: [note.copyWith(isTrash: true)],
        tags: [],
        lastSyncUsn: 2,
      );
      expect(await db.notebooks(account.cacheKey), isEmpty);
      final trash = await db.notes(account.cacheKey, trashOnly: true);
      expect(trash, hasLength(1));
      expect(trash.single.notebookId, '');
      expect(trash.single.content, 'preserved');
      expect(trash.single.isTrash, isTrue);
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [note.copyWith(isTrash: true)],
        tags: [],
        lastSyncUsn: 2,
      );
      expect(
        (await db.notes(account.cacheKey, trashOnly: true)).single.notebookId,
        '',
      );
    },
  );
}
