import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/notebook_creation_journal.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  late AppDatabase db;
  late SyncCoordinator sync;
  late AuthRepository repo;
  final requests = <String>[];
  var state = 4;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
    requests.clear();
    state = 4;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        expect(request.method, 'GET');
        expect(request.url.path, '/api2/user/getSyncState');
        return http.Response(jsonEncode({'LastSyncUsn': state}), 200);
      }),
    );
    sync = SyncCoordinator(api, db);
    repo = AuthRepository(api, db, MemorySessions(), sync);
  });
  tearDown(() => db.raw.close());
  for (final operation in [
    'incremental',
    'full',
    'upload',
    'attachment',
    'tag',
  ]) {
    test(
      'regressed server blocks $operation before any mutation or local acknowledgement',
      () async {
        final book = await NotebookCreationJournal(
          db.raw,
          account.cacheKey,
        ).create('Draft book', '');
        final note = await db.createLocalNote(
          account: account,
          notebookId: book.notebookId,
          isMarkdown: true,
          content: 'retain me',
        );
        final Future<void> task;
        switch (operation) {
          case 'incremental':
            task = sync.synchronize(account: account, token: 't');
          case 'full':
            task = sync.synchronizeFull(account: account, token: 't');
          case 'upload':
            task = sync.uploadPending(account: account, token: 't');
          case 'attachment':
            task = sync.runAttachmentUpload(
              () async => fail('must not upload'),
              account: account,
              token: 't',
              noteId: note.noteId,
            );
          default:
            task = repo.createTag(
              StoredSession(account: account, token: 't'),
              'Tag',
            );
        }
        await expectLater(task, throwsStateError);
        expect(requests, ['/api2/user/getSyncState']);
        expect(
          (await db.dirtyNotes(account.cacheKey)).single.content,
          'retain me',
        );
        expect(
          (await db.dirtyNotebooks(account.cacheKey)).single.title,
          'Draft book',
        );
        expect(
          await NotebookCreationJournal(
            db.raw,
            account.cacheKey,
          ).state(book.notebookId),
          'pending',
        );
        expect(await db.raw.query('note_create_attempts'), isEmpty);
        expect(await db.lastSyncUsn(account.cacheKey), 5);
        expect(sync.isBusy, isFalse);
      },
    );
  }
  test(
    'acknowledged note or notebook USN ahead of cursor is a rollback floor',
    () async {
      final draft = await db.createLocalNote(
        account: account,
        notebookId: 'book',
        isMarkdown: true,
      );
      await db.markNoteUploaded(
        account.cacheKey,
        draft,
        draft.copyWith(usn: 12),
      );
      await db.saveEditedText(account.cacheKey, draft.noteId, 'later', 'local');
      state = 10;
      await expectLater(
        sync.uploadPending(account: account, token: 't'),
        throwsStateError,
      );
      expect(await db.lastSyncUsn(account.cacheKey), 5);
      expect(await db.knownSyncUsn(account.cacheKey), 12);
      expect((await db.dirtyNotes(account.cacheKey)).single.usn, 12);
    },
  );
  test('known USN includes notebooks and tags but isolates other account histories', () async {
    final other = Account(
      userId: 'other',
      server: account.server,
      username: '',
      email: '',
      logo: '',
    );
    await db.replaceSnapshot(
      account: other,
      notebooks: [],
      notes: [
        Note.fromJson({'NoteId': 'other', 'Usn': 999}),
      ],
      tags: [],
      lastSyncUsn: 900,
    );
    await db.replaceSnapshot(
      account: account,
      notebooks: [
        Notebook.fromJson({'NotebookId': 'b', 'Usn': 7}),
      ],
      notes: [],
      tags: [
        {'Tag': 't', 'Usn': 8},
      ],
      lastSyncUsn: 5,
    );
    expect(await db.knownSyncUsn(account.cacheKey), 8);
    expect(await db.knownSyncUsn(other.cacheKey), 999);
    expect(await db.knownSyncUsn('missing'), 0);
  });
  test('clean upload-only operation remains entirely offline', () async {
    await sync.uploadPending(account: account, token: 't');
    expect(requests, isEmpty);
  });
}
