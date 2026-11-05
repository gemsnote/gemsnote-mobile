import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('v16 upgrade preserves drafts; global language survives logout, reset and reopen', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'gemsnote-language-',
    );
    final path = '${directory.path}/cache.sqlite';
    var db = await AppDatabase.open(databasePath: path);
    final account = Account(
      userId: 'u',
      server: Uri.parse('https://one.test/'),
      username: 'u',
      email: '',
      logo: '',
    );
    Future<void> snapshot() async => db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 3,
      expectedNoteSnapshot: await db.noteSnapshotFingerprint(account.cacheKey),
    );
    try {
      await snapshot();
      final note = await db.createLocalNote(
        account: account,
        notebookId: '',
        isMarkdown: true,
        content: '取消 {0} user content',
      );
      await db.raw.execute('DROP TABLE app_preferences');
      await db.raw.setVersion(16);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.languagePreference(), 'system');
      expect(await db.pendingNoteIds(account.cacheKey), {note.noteId});
      expect(
        (await db.dirtyNotes(account.cacheKey)).single.content,
        '取消 {0} user content',
      );
      await db.setLanguagePreference('en');
      await db.deactivate(account.cacheKey);
      await snapshot();
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      expect(await db.languagePreference(), 'en');
      await expectLater(db.setLanguagePreference('bad'), throwsArgumentError);
      expect(await db.languagePreference(), 'en');
    } finally {
      await db.raw.close();
      await directory.delete(recursive: true);
    }
  });
}
