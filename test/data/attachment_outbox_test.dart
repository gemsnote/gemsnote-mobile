import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/attachment_outbox.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late AttachmentOutbox outbox;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test'),
    username: 'u',
    email: '',
    logo: '',
  );
  final note = Note.fromJson({'NoteId': 'n', 'UserId': 'u', 'Usn': 3});
  final file = AttachmentUpload(
    name: '原件.txt',
    bytes: Uint8List.fromList([1, 2, 3]),
  );
  Future<void> snapshot(List<Note> notes) => db.replaceSnapshot(
    account: account,
    notebooks: [],
    notes: notes,
    tags: [],
    lastSyncUsn: 3,
  );
  Future<void> reopen() async {
    await db.raw.close();
    db = await AppDatabase.open(databasePath: '${dir.path}/notes.sqlite');
    outbox = AttachmentOutbox(db.raw, account);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gemsnote-outbox-');
    db = await AppDatabase.open(databasePath: '${dir.path}/notes.sqlite');
    await snapshot([note]);
    outbox = AttachmentOutbox(db.raw, account);
  });
  tearDown(() async {
    await db.raw.close();
    await dir.delete(recursive: true);
  });

  test('original survives process restart, cache clear and destructive server reset', () async {
    final id = await outbox.stage('n', file);
    await db.clearFileCache(account.cacheKey);
    await snapshot([]);
    await reopen();
    expect((await outbox.list()).single.state, 'pending');
    expect((await outbox.file(id)).bytes, [1, 2, 3]);
    expect(await db.notes(account.cacheKey), isEmpty);
    await outbox.remove(id);
    expect(await outbox.list(), isEmpty);
  });

  test(
    'uncertain state survives restart and rejects implicit duplicate sending',
    () async {
      final id = await outbox.stage('n', file);
      await outbox.markSending(id);
      await reopen();
      expect((await outbox.list()).single.state, 'uncertain');
      await expectLater(outbox.markSending(id), throwsStateError);
      await outbox.retryUncertain(id);
      await outbox.markSending(id);
      await expectLater(outbox.confirm(id, '../invalid'), throwsStateError);
      await outbox.confirm(id, '507f1f77bcf86cd799439012');
      await reopen();
      expect((await outbox.list()).single.state, 'uploaded');
      await expectLater(outbox.retryUncertain(id), throwsStateError);
      expect((await outbox.file(id)).bytes, [1, 2, 3]);
    },
  );

  test('same note and user IDs on another server cannot access or mutate originals', () async {
    final id = await outbox.stage('n', file);
    final other = AttachmentOutbox(
      db.raw,
      Account(
        userId: 'u',
        server: Uri.parse('https://other.test'),
        username: 'u',
        email: '',
        logo: '',
      ),
    );
    expect(await other.list(), isEmpty);
    await expectLater(other.file(id), throwsStateError);
    await expectLater(other.markSending(id), throwsStateError);
    await other.remove(id);
    expect((await outbox.file(id)).bytes, [1, 2, 3]);
  });

  test('new offline notes accept attachments; missing, foreign and trashed notes do not', () async {
    final created = await db.createLocalNote(
      account: account,
      notebookId: '',
      isMarkdown: true,
    );
    await outbox.stage(created.noteId, file);
    expect((await outbox.list(noteId: created.noteId)).length, 1);
    await db.markNoteUploaded(
      account.cacheKey,
      created,
      created.copyWith(usn: 4),
    );
    await expectLater(outbox.stage('missing', file), throwsStateError);
    await snapshot([note.copyWith(isTrash: true)]);
    await expectLater(outbox.stage('n', file), throwsStateError);
    await snapshot([
      Note.fromJson({'NoteId': 'n', 'UserId': 'other', 'Usn': 3}),
    ]);
    await expectLater(outbox.stage('n', file), throwsStateError);
  });

  test(
    'quota rejects new originals without evicting existing pending files',
    () async {
      for (var i = 0; i < AttachmentOutbox.maxItems; i++) {
        await outbox.stage('n', file);
      }
      await expectLater(outbox.stage('n', file), throwsStateError);
      final entries = await outbox.list();
      expect(entries.length, AttachmentOutbox.maxItems);
      expect((await outbox.file(entries.first.id)).bytes, [1, 2, 3]);
      for (final item in entries) {
        await outbox.remove(item.id);
      }
      // SQLite zeroblob exercises the persisted aggregate limit without allocating
      // a second 64 MiB Dart buffer in this test process.
      final id = await outbox.stage('n', file);
      await db.raw.rawUpdate(
        'UPDATE attachment_outbox SET bytes = zeroblob(?) WHERE id = ?',
        [AttachmentOutbox.maxBytes, id],
      );
      await expectLater(outbox.stage('n', file), throwsStateError);
      expect((await outbox.list()).single.size, AttachmentOutbox.maxBytes);
    },
  );

  test('v10 upgrade preserves notes, cursor and downloads', () async {
    await db.raw.execute('DROP TABLE attachment_outbox');
    await db.raw.setVersion(10);
    await reopen();
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
    expect((await db.notes(account.cacheKey)).single.noteId, 'n');
    expect(await db.lastSyncUsn(account.cacheKey), 3);
    await outbox.stage('n', file);
    expect((await outbox.list()).length, 1);
  });

  test(
    'v11 upgrade preserves old attachment originals and upload states',
    () async {
      final id = await outbox.stage('n', file);
      await outbox.markSending(id);
      await db.raw.execute('ALTER TABLE attachment_outbox DROP COLUMN kind');
      await db.raw.setVersion(11);
      await reopen();
      final restored = (await outbox.list()).single;
      expect(restored.kind, 'attachment');
      expect(restored.state, 'uncertain');
      expect((await outbox.file(id)).bytes, [1, 2, 3]);
    },
  );
}
