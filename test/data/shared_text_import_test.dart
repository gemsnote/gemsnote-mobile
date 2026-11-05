import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/shared_text_inbox.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late AuthRepository repo;
  late StoredSession session;
  final source = SharedText(
    id: '507f1f77bcf86cd799439012',
    title: 'Title',
    text: 'Text https://example.test',
  );
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    session = StoredSession(
      account: Account(
        userId: 'u',
        server: Uri.parse('https://example.test'),
        username: 'u',
        email: '',
        logo: '',
      ),
      token: 't',
    );
    await db.replaceSnapshot(
      account: session.account,
      notebooks: [
        Notebook.fromJson({'NotebookId': 'book', 'Title': 'Book'}),
      ],
      notes: [],
      tags: [],
      lastSyncUsn: 2,
    );
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => throw StateError('must stay offline'),
      ),
    );
    repo = AuthRepository(api, db, MemorySessions(), SyncCoordinator(api, db));
  });
  tearDown(() => db.raw.close());

  test('binary share imports note and original atomically; failed native ack retry preserves edits', () async {
    final resource = SharedText(
      id: source.id,
      title: 'file',
      text: 'caption',
      resourceKind: 'attachment',
      resourceName: 'document.pdf',
      resourceSize: 3,
    );
    final bytes = Uint8List.fromList([1, 2, 3]);
    await repo.importSharedText(
      session,
      resource,
      'book',
      resourceBytes: bytes,
    );
    expect(
      (await repo.pendingAttachments(session)).single.name,
      'document.pdf',
    );
    expect((await repo.pendingAttachments(session)).single.noteId, source.id);
    await db.saveEditedText(
      session.account.cacheKey,
      source.id,
      'edited',
      'new body',
    );
    final again = await repo.importSharedText(
      session,
      resource,
      'book',
      resourceBytes: bytes,
    );
    expect(again.content, 'new body');
    expect((await repo.pendingAttachments(session)).length, 1);
    expect(
      (await repo.stagedAttachment(
        session,
        (await repo.pendingAttachments(session)).single.id,
      )).bytes,
      bytes,
    );
    expect(await db.lastSyncUsn(session.account.cacheKey), 2);
  });

  test('outbox write failure rolls back imported note, retaining native share for retry', () async {
    final resource = SharedText(
      id: source.id,
      title: 'file',
      text: 'caption',
      resourceKind: 'attachment',
      resourceName: 'a.bin',
      resourceSize: 1,
    );
    await db.raw.execute(
      "CREATE TRIGGER fail_share BEFORE INSERT ON attachment_outbox BEGIN SELECT RAISE(ABORT, 'disk full'); END",
    );
    await expectLater(
      repo.importSharedText(
        session,
        resource,
        'book',
        resourceBytes: Uint8List(1),
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(await db.notes(session.account.cacheKey), isEmpty);
    expect(await repo.pendingAttachments(session), isEmpty);
    await db.raw.execute('DROP TRIGGER fail_share');
    await repo.importSharedText(
      session,
      resource,
      'book',
      resourceBytes: Uint8List(1),
    );
    expect((await db.notes(session.account.cacheKey)).length, 1);
  });

  test('missing or invalid image bytes do not create a partial note', () async {
    final resource = SharedText(
      id: source.id,
      title: 'image',
      text: 'caption',
      resourceKind: 'image',
      resourceName: 'image.png',
      resourceSize: 3,
    );
    await expectLater(
      repo.importSharedText(session, resource, 'book'),
      throwsStateError,
    );
    await expectLater(
      repo.importSharedText(
        session,
        resource,
        'book',
        resourceBytes: Uint8List(3),
      ),
      throwsFormatException,
    );
    expect(await db.notes(session.account.cacheKey), isEmpty);
    expect(await repo.pendingAttachments(session), isEmpty);
  });

  test('shared PNG becomes normalized image task without sending requests or temporary paths', () async {
    final bytes = File('assets/images/gemsnote_s.png').readAsBytesSync();
    final resource = SharedText(
      id: source.id,
      title: 'image',
      text: 'caption',
      resourceKind: 'image',
      resourceName: 'original.png',
      resourceSize: bytes.length,
    );
    final note = await repo.importSharedText(
      session,
      resource,
      'book',
      resourceBytes: bytes,
    );
    expect(note.content, 'caption');
    final item = (await repo.pendingAttachments(session)).single;
    expect(item.isImage, isTrue);
    expect(item.state, 'pending');
    expect(item.name, 'image.png');
  });
  test(
    'import creates dirty Markdown with stable ID and complete source offline',
    () async {
      final note = await repo.importSharedText(session, source, 'book');
      expect(note.noteId, source.id);
      expect(note.content, source.text);
      expect(note.isMarkdown, true);
      expect(note.notebookId, 'book');
      expect(note.usn, 0);
      expect(await db.pendingNoteIds(session.account.cacheKey), {source.id});
      expect(await db.lastSyncUsn(session.account.cacheKey), 2);
    },
  );
  test(
    'acknowledgement retry does not duplicate or overwrite later edits',
    () async {
      await repo.importSharedText(session, source, 'book');
      await db.saveEditedText(
        session.account.cacheKey,
        source.id,
        'Changed',
        'New body',
      );
      final again = await repo.importSharedText(session, source, 'book');
      expect(again.title, 'Changed');
      expect(again.content, 'New body');
      expect((await db.notes(session.account.cacheKey)).length, 1);
    },
  );
  test(
    'missing notebook and foreign account claim do not write a note',
    () async {
      await expectLater(
        repo.importSharedText(session, source, 'gone'),
        throwsStateError,
      );
      final claimed = SharedText(
        id: source.id,
        title: source.title,
        text: source.text,
        accountKey: 'other',
      );
      await expectLater(
        Future.sync(() => repo.importSharedText(session, claimed, 'book')),
        throwsStateError,
      );
      expect(await db.notes(session.account.cacheKey), isEmpty);
    },
  );
}
