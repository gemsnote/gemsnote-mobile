import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/default_editor.dart';
import 'package:gemsnote/domain/models/note_sort.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase db;
  late Directory directory;
  late String path;
  Account account(String server, [String user = 'u']) => Account(
    userId: user,
    server: Uri.parse(server),
    username: user,
    email: '',
    logo: '',
  );
  final a = account('https://one.test/');
  final b = account('https://two.test/');
  final c = account('https://one.test/', 'other');
  Future<void> snapshot(Account account) => db.replaceSnapshot(
    account: account,
    notebooks: [],
    notes: [],
    tags: [],
    lastSyncUsn: 3,
  );
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('gemsnote-editor-');
    path = '${directory.path}/cache.sqlite';
    db = await AppDatabase.open(databasePath: path);
    await snapshot(a);
    await snapshot(b);
    await snapshot(c);
  });
  tearDown(() async {
    await db.raw.close();
    await directory.delete(recursive: true);
  });

  test(
    'preference isolates server and user and survives reopen, logout and reset',
    () async {
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.html);
      await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
      expect(await db.defaultEditor(b.cacheKey), DefaultEditor.html);
      expect(await db.defaultEditor(c.cacheKey), DefaultEditor.html);
      await db.deactivate(a.cacheKey);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
      await snapshot(a);
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
      expect(await db.pendingNoteIds(a.cacheKey), isEmpty);
      expect(await db.lastSyncUsn(a.cacheKey), 3);
    },
  );
  test('v5 migration retains dirty content, cursor and activates default preference', () async {
    final note = await db.createLocalNote(
      account: a,
      notebookId: '',
      isMarkdown: false,
      content: '<p>unsynced</p>',
    );
    await db.raw.execute('DROP TABLE account_preferences');
    await db.raw.setVersion(5);
    await db.raw.close();
    db = await AppDatabase.open(databasePath: path);
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
    expect((await db.dirtyNotes(a.cacheKey)).single.content, '<p>unsynced</p>');
    expect(await db.pendingNoteIds(a.cacheKey), {note.noteId});
    expect(await db.lastSyncUsn(a.cacheKey), 3);
    expect(await db.defaultEditor(a.cacheKey), DefaultEditor.html);
    await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
    expect((await db.dirtyNotes(a.cacheKey)).single.isMarkdown, false);
  });
  test(
    'sort isolates accounts and survives reopen, reset and editor changes',
    () async {
      expect(await db.noteSort(a.cacheKey), NoteSort.updatedDescending);
      for (final sort in NoteSort.values) {
        await db.setNoteSort(a.cacheKey, sort);
        expect(await db.noteSort(a.cacheKey), sort);
      }
      await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
      expect(await db.noteSort(a.cacheKey), NoteSort.titleDescending);
      expect(await db.noteSort(b.cacheKey), NoteSort.updatedDescending);
      expect(await db.noteSort(c.cacheKey), NoteSort.updatedDescending);
      await db.deactivate(a.cacheKey);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.noteSort(a.cacheKey), NoteSort.titleDescending);
      await snapshot(a);
      expect(await db.noteSort(a.cacheKey), NoteSort.titleDescending);
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
      expect(await db.pendingNoteIds(a.cacheKey), isEmpty);
      expect(await db.lastSyncUsn(a.cacheKey), 3);
      await expectLater(
        db.setNoteSort('missing', NoteSort.titleAscending),
        throwsStateError,
      );
    },
  );
  test(
    'v6 upgrade preserves dirty notes and existing editor preference',
    () async {
      final note = await db.createLocalNote(
        account: a,
        notebookId: '',
        isMarkdown: true,
        content: 'unsynced',
      );
      await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
      await db.raw.execute('DROP TABLE account_note_sort');
      await db.raw.setVersion(6);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
      expect(await db.noteSort(a.cacheKey), NoteSort.updatedDescending);
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
      expect(await db.pendingNoteIds(a.cacheKey), {note.noteId});
      expect((await db.dirtyNotes(a.cacheKey)).single.content, 'unsynced');
      expect(await db.lastSyncUsn(a.cacheKey), 3);
    },
  );
  test(
    'v22 upgrade preserves cached work and enables creation sort preferences',
    () async {
      final note = await db.createLocalNote(
        account: a,
        notebookId: '',
        isMarkdown: true,
        content: 'unsynced',
      );
      await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
      await db.raw.execute('DROP TABLE account_note_sort');
      await db.raw.execute("""CREATE TABLE account_note_sort (
      account_id TEXT PRIMARY KEY,
      note_sort TEXT NOT NULL CHECK (note_sort IN (
        'updatedDescending', 'updatedAscending', 'titleAscending', 'titleDescending'))
    )""");
      await db.setNoteSort(a.cacheKey, NoteSort.titleAscending);
      await db.setNoteSort(b.cacheKey, NoteSort.updatedAscending);
      await db.raw.setVersion(22);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
      expect(await db.noteSort(a.cacheKey), NoteSort.titleAscending);
      expect(await db.noteSort(b.cacheKey), NoteSort.updatedAscending);
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
      expect(await db.pendingNoteIds(a.cacheKey), {note.noteId});
      expect((await db.dirtyNotes(a.cacheKey)).single.content, 'unsynced');
      expect(await db.lastSyncUsn(a.cacheKey), 3);
      await db.setNoteSort(a.cacheKey, NoteSort.createdAscending);
      await db.setNoteSort(b.cacheKey, NoteSort.createdDescending);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.noteSort(a.cacheKey), NoteSort.createdAscending);
      expect(await db.noteSort(b.cacheKey), NoteSort.createdDescending);
      expect(await db.pendingNoteIds(a.cacheKey), {note.noteId});
    },
  );

  test(
    'cache opt-in persists across logout and reset and isolates accounts',
    () async {
      expect(await db.autoCacheFiles(a.cacheKey), false);
      await db.setAutoCacheFiles(a.cacheKey, true);
      await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
      await db.setNoteSort(a.cacheKey, NoteSort.titleAscending);
      expect(await db.autoCacheFiles(b.cacheKey), false);
      expect(await db.autoCacheFiles(c.cacheKey), false);
      await db.deactivate(a.cacheKey);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.autoCacheFiles(a.cacheKey), true);
      await snapshot(a);
      expect(await db.autoCacheFiles(a.cacheKey), true);
      expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
      expect(await db.noteSort(a.cacheKey), NoteSort.titleAscending);
      expect(await db.pendingNoteIds(a.cacheKey), isEmpty);
      expect(await db.lastSyncUsn(a.cacheKey), 3);
      await db.setAutoCacheFiles(a.cacheKey, false);
      expect(await db.autoCacheFiles(a.cacheKey), false);
      await expectLater(
        db.setAutoCacheFiles('missing', true),
        throwsStateError,
      );
    },
  );

  test(
    'automatic sync preference survives restart and stays account-scoped',
    () async {
      expect(await db.autoSync(a.cacheKey), false);
      await db.setAutoCacheFiles(a.cacheKey, true);
      await db.setAutoSync(a.cacheKey, true);
      await db.setAutoCacheFiles(a.cacheKey, false);
      expect(await db.autoSync(a.cacheKey), true);
      expect(await db.autoSync(b.cacheKey), false);
      await db.setAutoSync(b.cacheKey, true);
      await db.setAutoSync(a.cacheKey, false);
      expect(await db.autoSync(b.cacheKey), true);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.autoSync(a.cacheKey), false);
      expect(await db.autoSync(b.cacheKey), true);
      await snapshot(b);
      expect(await db.autoSync(b.cacheKey), true);
      await expectLater(db.setAutoSync('missing', true), throwsStateError);
    },
  );

  test(
    'v19 upgrade preserves cache preference and defaults sync off',
    () async {
      await db.raw.execute('DROP TABLE account_cache_preferences');
      await db.raw.execute('''CREATE TABLE account_cache_preferences (
      account_id TEXT PRIMARY KEY,
      enabled INTEGER NOT NULL CHECK (enabled IN (0, 1))
    )''');
      await db.raw.insert('account_cache_preferences', {
        'account_id': a.cacheKey,
        'enabled': 1,
      });
      await db.raw.setVersion(19);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
      expect(await db.autoCacheFiles(a.cacheKey), true);
      expect(await db.autoSync(a.cacheKey), false);
      await db.setAutoSync(a.cacheKey, true);
      expect(await db.autoCacheFiles(a.cacheKey), true);
    },
  );

  test('v7 upgrade preserves pending content and preferences; caching defaults off', () async {
    final note = await db.createLocalNote(
      account: a,
      notebookId: '',
      isMarkdown: true,
      content: 'unsynced',
    );
    await db.setDefaultEditor(a.cacheKey, DefaultEditor.markdown);
    await db.setNoteSort(a.cacheKey, NoteSort.titleAscending);
    await db.raw.execute('DROP TABLE account_cache_preferences');
    await db.raw.setVersion(7);
    await db.raw.close();
    db = await AppDatabase.open(databasePath: path);
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
    expect(await db.autoCacheFiles(a.cacheKey), false);
    expect(await db.defaultEditor(a.cacheKey), DefaultEditor.markdown);
    expect(await db.noteSort(a.cacheKey), NoteSort.titleAscending);
    expect(await db.pendingNoteIds(a.cacheKey), {note.noteId});
    expect((await db.dirtyNotes(a.cacheKey)).single.content, 'unsynced');
    expect(await db.lastSyncUsn(a.cacheKey), 3);
  });

  test('missing accounts cannot acquire orphan preferences', () async {
    await expectLater(
      db.setDefaultEditor('missing', DefaultEditor.markdown),
      throwsStateError,
    );
    expect(await db.raw.query('account_preferences'), isEmpty);
  });
}
