import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/notebook_creation_journal.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

class CreationApi extends Api2Client {
  @override
  Future<int> getSyncUsn({required Uri server, required String token}) async =>
      100;
  int creates = 0, usn = 5;
  bool loseResponse = false;
  final books = <Notebook>[];
  final notes = <Note>[];
  final storedNotes = <String, Note>{};
  Future<void> Function()? duringCreate;
  @override
  Future<Notebook> saveNotebook({
    required Uri server,
    required String token,
    required String title,
    String? parentNotebookId,
    Notebook? existing,
    String? clientNotebookId,
  }) async {
    expect(existing, isNull);
    if (clientNotebookId != null &&
        books.any((book) => book.notebookId == clientNotebookId)) {
      return books.singleWhere((book) => book.notebookId == clientNotebookId);
    }
    creates++;
    final book = Notebook(
      notebookId:
          clientNotebookId ??
          (100 + creates).toRadixString(16).padLeft(24, '0'),
      parentNotebookId: parentNotebookId ?? '',
      title: title,
      sequence: 0,
      usn: ++usn,
      numberNotes: 0,
      isDeleted: false,
    );
    if (book.parentNotebookId.isNotEmpty) {
      expect(books.any((b) => b.notebookId == book.parentNotebookId), isTrue);
    }
    books.add(book);
    await duringCreate?.call();
    if (loseResponse) throw StateError('response lost');
    return book;
  }

  @override
  Future<Note> addNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    expect(books.any((b) => b.notebookId == note.notebookId), isTrue);
    notes.add(note);
    return storedNotes[note.noteId] = note.copyWith(usn: ++usn);
  }

  @override
  Future<({Note note, bool filesConfirmedEmpty})> getConflictSnapshot({
    required Uri server,
    required String token,
    required String noteId,
  }) async => (note: storedNotes[noteId]!, filesConfirmedEmpty: true);

  @override
  Future<List<Notebook>> getNotebooks({
    required Uri server,
    required String token,
    required int afterUsn,
    int maxEntry = 100,
  }) async => books.where((b) => b.usn > afterUsn).toList();
}

void main() {
  late Directory directory;
  late AppDatabase db;
  late CreationApi api;
  late AuthRepository repo;
  late SyncCoordinator sync;
  late NotebookCreationJournal journal;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test'),
    username: 'u',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 't');
  void bind() {
    sync = SyncCoordinator(api, db);
    repo = AuthRepository(api, db, MemorySessions(), sync);
    journal = NotebookCreationJournal(db.raw, account.cacheKey);
  }

  Future<void> reopen() async {
    await db.raw.close();
    db = await AppDatabase.open(databasePath: '${directory.path}/notes.sqlite');
    bind();
  }

  Future<void> push() => sync.uploadPending(account: account, token: 't');
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gemsnote-create-book-');
    db = await AppDatabase.open(databasePath: '${directory.path}/notes.sqlite');
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
    api = CreationApi();
    bind();
  });
  tearDown(() async {
    await db.raw.close();
    await directory.delete(recursive: true);
  });

  test('API2 1.1 retries the durable creation key after restart without duplicates', () async {
    final enhanced = Account(
      userId: account.userId,
      server: account.server,
      username: account.username,
      email: '',
      logo: '',
      apiVersion: '1.1.0',
    );
    await db.activateCachedAccount(enhanced);
    final book = await repo.createOfflineNotebook(
      StoredSession(account: enhanced, token: 't'),
      'Safe retry',
      '',
    );
    api.loseResponse = true;
    await expectLater(
      sync.uploadPending(account: enhanced, token: 't'),
      throwsStateError,
    );
    expect(api.books.single.notebookId, book.notebookId);
    await reopen();
    expect((await db.activeAccount())!.apiVersion, '1.1.0');
    api.loseResponse = false;
    await sync.uploadPending(account: enhanced, token: 't');
    expect(api.creates, 1);
    expect(api.books.length, 1);
    expect(await journal.state(book.notebookId), 'complete');
    expect((await db.notebooks(enhanced.cacheKey)).single.isDirty, false);
  });

  test('offline hierarchy survives restart; create uploads parents then remaps children and notes', () async {
    final parent = await repo.createOfflineNotebook(session, ' Parent ', '');
    final child = await repo.createOfflineNotebook(
      session,
      'Child',
      parent.notebookId,
    );
    await repo.queueNotebookRename(session, parent.notebookId, 'Renamed');
    await expectLater(
      repo.queueNotebookMove(session, parent.notebookId, child.notebookId),
      throwsFormatException,
    );
    final note = await db.createLocalNote(
      account: account,
      notebookId: child.notebookId,
      isMarkdown: true,
      content: 'local body',
    );
    expect(api.creates, 0);
    await reopen();
    expect((await db.dirtyNotebooks(account.cacheKey)).length, 2);
    await push();
    expect(api.books.map((b) => b.title), ['Renamed', 'Child']);
    expect(api.books.last.parentNotebookId, api.books.first.notebookId);
    expect(api.notes.single.notebookId, api.books.last.notebookId);
    expect(api.notes.single.content, 'local body');
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
    expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
    expect(await db.lastSyncUsn(account.cacheKey), 5);
    expect(await journal.resolve(child.notebookId), api.books.last.notebookId);
    expect(
      (await db.notes(
        account.cacheKey,
        notebookId: child.notebookId,
      )).single.noteId,
      note.noteId,
    );
    await db.saveLocalNote(
      account.cacheKey,
      note.copyWith(title: 'stale page edit'),
    );
    expect(
      (await db.notes(account.cacheKey)).single.notebookId,
      api.books.last.notebookId,
    );
    final created = await db.createLocalNote(
      account: account,
      notebookId: child.notebookId,
      isMarkdown: true,
    );
    expect(created.notebookId, api.books.last.notebookId);
  });

  test('lost response freezes creation across restart; explicit association prevents duplicates', () async {
    final parent = await repo.createOfflineNotebook(session, 'Parent', '');
    final child = await repo.createOfflineNotebook(
      session,
      'Child',
      parent.notebookId,
    );
    await db.createLocalNote(
      account: account,
      notebookId: child.notebookId,
      isMarkdown: true,
    );
    api.loseResponse = true;
    await expectLater(push(), throwsStateError);
    expect(api.creates, 1);
    expect(await journal.state(parent.notebookId), 'uncertain');
    await expectLater(
      repo.queueNotebookRename(session, parent.notebookId, 'Changed'),
      throwsStateError,
    );
    await reopen();
    await expectLater(push(), throwsStateError);
    expect(api.creates, 1);
    expect(api.notes, isEmpty);
    final candidates = await repo.notebookCreationCandidates(
      session,
      parent.notebookId,
    );
    expect(candidates.length, 1);
    await repo.confirmNotebookCreation(
      session,
      parent.notebookId,
      candidates.single,
    );
    api.loseResponse = false;
    await push();
    expect(api.creates, 2);
    expect(api.notes.length, 1);
    expect(await journal.state(parent.notebookId), 'complete');
  });

  test(
    'explicit retry restores pending state without sending a request',
    () async {
      final book = await repo.createOfflineNotebook(session, 'Retry', '');
      await journal.begin(book.notebookId);
      await repo.retryNotebookCreation(session, book.notebookId);
      expect(api.creates, 0);
      expect(await journal.state(book.notebookId), 'pending');
      await push();
      expect(api.creates, 1);
    },
  );

  test(
    'acknowledgement remap is atomic and can be repeated after local failure',
    () async {
      final parent = await repo.createOfflineNotebook(session, 'Parent', '');
      final child = await repo.createOfflineNotebook(
        session,
        'Child',
        parent.notebookId,
      );
      await db.createLocalNote(
        account: account,
        notebookId: parent.notebookId,
        isMarkdown: true,
      );
      final request = await journal.begin(parent.notebookId);
      final remote = await api.saveNotebook(
        server: account.server,
        token: 't',
        title: 'Parent',
      );
      await db.raw.execute(
        "CREATE TRIGGER fail_remap BEFORE UPDATE OF notebook_server_id ON notes BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );
      await expectLater(
        journal.confirm(request, remote),
        throwsA(isA<DatabaseException>()),
      );
      expect(await journal.state(parent.notebookId), 'uncertain');
      expect(
        (await db.notes(account.cacheKey)).single.notebookId,
        parent.notebookId,
      );
      expect(
        (await db.notebooks(account.cacheKey))
            .firstWhere((b) => b.notebookId == child.notebookId)
            .parentNotebookId,
        parent.notebookId,
      );
      await db.raw.execute('DROP TRIGGER fail_remap');
      await journal.confirm(request, remote);
      expect(
        (await db.notes(account.cacheKey)).single.notebookId,
        remote.notebookId,
      );
      expect(api.creates, 1);
    },
  );

  test(
    'attachment action creates only target ancestors before uploading note',
    () async {
      final parent = await repo.createOfflineNotebook(session, 'Parent', '');
      final child = await repo.createOfflineNotebook(
        session,
        'Child',
        parent.notebookId,
      );
      final other = await repo.createOfflineNotebook(session, 'Other', '');
      final note = await db.createLocalNote(
        account: account,
        notebookId: child.notebookId,
        isMarkdown: true,
      );
      var ran = false;
      await sync.runAttachmentUpload(
        () async {
          ran = true;
        },
        account: account,
        token: 't',
        noteId: note.noteId,
      );
      expect(ran, isTrue);
      expect(api.books.map((b) => b.title), ['Parent', 'Child']);
      expect(api.notes.single.noteId, note.noteId);
      expect(
        (await db.dirtyNotebooks(account.cacheKey)).single.notebookId,
        other.notebookId,
      );
    },
  );

  test('pending parent cannot be sent as remote ID and other accounts cannot map local IDs', () async {
    final parent = await journal.create('Parent', '');
    final child = await journal.create('Child', parent.notebookId);
    await expectLater(journal.begin(child.notebookId), throwsStateError);
    expect(await journal.state(child.notebookId), 'pending');
    final other = NotebookCreationJournal(db.raw, 'other');
    expect(await other.state(parent.notebookId), isNull);
    await expectLater(other.begin(parent.notebookId), throwsStateError);
    await expectLater(
      journal.create('Missing parent', 'gone'),
      throwsStateError,
    );
    expect((await db.notebooks(account.cacheKey)).length, 2);
  });

  test('v12 upgrade preserves drafts and existing resource tables', () async {
    await db.createLocalNote(
      account: account,
      notebookId: '',
      isMarkdown: true,
      content: 'draft',
    );
    await db.raw.execute('DROP TABLE notebook_creations');
    await db.raw.setVersion(12);
    await reopen();
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
    expect((await db.notes(account.cacheKey)).single.content, 'draft');
    expect(await db.lastSyncUsn(account.cacheKey), 5);
    expect(await repo.pendingAttachments(session), isEmpty);
    await journal.create('New', '');
    expect((await db.dirtyNotebooks(account.cacheKey)).length, 1);
  });

  test(
    'in-flight create freezes notebook metadata but preserves new note edits',
    () async {
      final parent = await journal.create('Parent', '');
      api.duringCreate = () async {
        await expectLater(
          db.editLocalNotebook(
            account.cacheKey,
            parent.notebookId,
            title: 'late rename',
          ),
          throwsStateError,
        );
        await expectLater(
          repo.retryNotebookCreation(session, parent.notebookId),
          throwsStateError,
        );
        await db.createLocalNote(
          account: account,
          notebookId: parent.notebookId,
          isMarkdown: true,
          content: 'created during request',
        );
      };
      await push();
      expect(api.creates, 1);
      expect(api.notes.single.content, 'created during request');
      expect(api.notes.single.notebookId, api.books.single.notebookId);
    },
  );

  test(
    'mismatched create result cannot remap or overwrite a notebook',
    () async {
      final local = await journal.create('Local', '');
      final request = await journal.begin(local.notebookId);
      final wrong = await api.saveNotebook(
        server: account.server,
        token: 't',
        title: 'Wrong title',
      );
      await expectLater(journal.confirm(request, wrong), throwsStateError);
      expect(await journal.state(local.notebookId), 'uncertain');
      expect((await db.notebooks(account.cacheKey)).single.title, 'Local');
      expect(await journal.resolve(local.notebookId), local.notebookId);
    },
  );
}
