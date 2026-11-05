import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;
import 'notebook_move_test.dart' show book, source, child, target;

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://notes.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 't');
  late AppDatabase db;
  late Directory temp;
  late AuthRepository repo;
  late SyncCoordinator sync;
  late List<Notebook> remoteBooks;
  late List<String> requests;
  int serverUsn = 20;
  Completer<void>? gate;
  Completer<void>? arrived;
  Notebook remote({
    String id = source,
    String parent = '',
    int usn = 10,
    String title = 'Remote',
    bool deleted = false,
  }) => Notebook(
    notebookId: id,
    parentNotebookId: parent,
    title: title,
    sequence: 7,
    usn: usn,
    numberNotes: 5,
    isDeleted: deleted,
  );
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    temp = await Directory.systemTemp.createTemp('notebook-conflict-');
    db = await AppDatabase.open(databasePath: '${temp.path}/cache');
    await db.replaceSnapshot(
      account: account,
      notebooks: [book(source, ''), book(child, source), book(target, '')],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
    await db.editLocalNotebook(account.cacheKey, source, title: 'Local');
    remoteBooks = [remote(), book(child, source), book(target, '')];
    requests = [];
    gate = null;
    arrived = null;
    serverUsn = 20;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        requests.add(request.url.path);
        if (request.url.path == '/api2/user/getSyncState') {
          return http.Response(jsonEncode({'LastSyncUsn': serverUsn}), 200);
        }
        expect(request.url.path, '/api2/notebook/getSyncNotebooks');
        arrived?.complete();
        arrived = null;
        await gate?.future;
        return http.Response(
          jsonEncode(
            remoteBooks
                .map(
                  (n) => {
                    'NotebookId': n.notebookId,
                    'ParentNotebookId': n.parentNotebookId,
                    'Title': n.title,
                    'Seq': n.sequence,
                    'Usn': n.usn,
                    'NumberNotes': n.numberNotes,
                    'IsDeleted': n.isDeleted,
                  },
                )
                .toList(),
          ),
          200,
        );
      }),
    );
    sync = SyncCoordinator(api, db);
    repo = AuthRepository(api, db, MemorySessions(), sync);
  });
  tearDown(() async {
    await db.raw.close();
    await temp.delete(recursive: true);
  });
  for (final keep in [true, false]) {
    test(
      'review is read-only; resolve persists $keep without sending a write or replacing drafts',
      () async {
        final draft = await db.createLocalNote(
          account: account,
          notebookId: source,
          isMarkdown: true,
          content: 'unsynced body',
        );
        await db.editLocalNotebook(
          account.cacheKey,
          target,
          title: 'Other pending',
        );
        final reviewed = await repo.reviewNotebookConflict(session, source);
        expect((await db.dirtyNotebooks(account.cacheKey)).length, 2);
        expect(reviewed.local.title, 'Local');
        expect(reviewed.remote.title, 'Remote');
        await repo.resolveNotebookConflict(session, reviewed, keepLocal: keep);
        final row = (await db.notebooks(account.cacheKey))
            .firstWhere((n) => n.notebookId == source);
        expect(row.title, keep ? 'Local' : 'Remote');
        expect(row.usn, 10);
        expect(row.isDirty, keep);
        expect(
          (await db.notebooks(account.cacheKey))
              .firstWhere((n) => n.notebookId == child)
              .parentNotebookId,
          source,
        );
        expect(
          (await db.dirtyNotes(account.cacheKey)).single.content,
          'unsynced body',
        );
        expect(await db.pendingNoteIds(account.cacheKey), {draft.noteId});
        expect(
          (await db.dirtyNotebooks(account.cacheKey))
              .any((n) => n.title == 'Other pending'),
          isTrue,
        );
        expect(await db.lastSyncUsn(account.cacheKey), 5);
        await db.raw.close();
        db = await AppDatabase.open(databasePath: '${temp.path}/cache');
        expect(
          (await db.notebooks(account.cacheKey))
              .firstWhere((n) => n.notebookId == source)
              .title,
          row.title,
        );
        expect(requests, [
          '/api2/user/getSyncState',
          '/api2/notebook/getSyncNotebooks',
          '/api2/user/getSyncState',
          '/api2/notebook/getSyncNotebooks',
        ]);
      },
    );
  }
  test('fresh local edits, fresh remote edits, account changes and rollback reject stale decisions', () async {
    final reviewed = await repo.reviewNotebookConflict(session, source);
    remoteBooks[0] = remote(title: 'Changed', usn: 11);
    await expectLater(
      repo.resolveNotebookConflict(session, reviewed, keepLocal: true),
      throwsStateError,
    );
    remoteBooks[0] = remote();
    await db.editLocalNotebook(account.cacheKey, source, title: 'Later local');
    await expectLater(
      repo.resolveNotebookConflict(session, reviewed, keepLocal: false),
      throwsStateError,
    );
    final other = StoredSession(
      account: Account(
        userId: 'u',
        server: Uri.parse('https://other.test/'),
        username: 'u',
        email: '',
        logo: '',
      ),
      token: 'other',
    );
    final count = requests.length;
    await expectLater(
      repo.resolveNotebookConflict(other, reviewed, keepLocal: false),
      throwsStateError,
    );
    expect(requests.length, count);
    serverUsn = 4;
    await expectLater(
      repo.reviewNotebookConflict(session, source),
      throwsStateError,
    );
    expect(
      (await db.dirtyNotebooks(account.cacheKey)).single.title,
      'Later local',
    );
    expect(await db.lastSyncUsn(account.cacheKey), 5);
  });
  test('review and apply share the sync lock; edits during network read are preserved', () async {
    final reviewed = await repo.reviewNotebookConflict(session, source);
    gate = Completer<void>();
    arrived = Completer<void>();
    final arrival = arrived!.future;
    final pending = repo.resolveNotebookConflict(
      session,
      reviewed,
      keepLocal: false,
    );
    await arrival;
    await expectLater(
      sync.uploadPending(account: account, token: 't'),
      throwsStateError,
    );
    await db.editLocalNotebook(account.cacheKey, source, title: 'Concurrent');
    gate!.complete();
    await expectLater(pending, throwsStateError);
    expect(
      (await db.dirtyNotebooks(account.cacheKey)).single.title,
      'Concurrent',
    );
  });
  test('remote move imports only necessary unknown ancestors and keeps other pending parents', () async {
    const newParent = '507f1f77bcf86cd799439099';
    remoteBooks = [
      remote(parent: newParent),
      remote(id: newParent, parent: target, title: 'New parent', usn: 9),
      book(target, ''),
      book(child, source),
    ];
    await db.editLocalNotebook(account.cacheKey, target, title: 'Local parent');
    final reviewed = await repo.reviewNotebookConflict(session, source);
    await repo.resolveNotebookConflict(session, reviewed, keepLocal: false);
    final books = await db.notebooks(account.cacheKey);
    expect(
      books.firstWhere((n) => n.notebookId == newParent).title,
      'New parent',
    );
    expect(
      books.firstWhere((n) => n.notebookId == target).title,
      'Local parent',
    );
    expect(
      books.firstWhere((n) => n.notebookId == source).parentNotebookId,
      newParent,
    );
    expect(await db.lastSyncUsn(account.cacheKey), 5);
  });
  test('new parent changed during review rejects application', () async {
    const newParent = '507f1f77bcf86cd799439099';
    remoteBooks = [
      remote(parent: newParent),
      remote(id: newParent, title: 'Parent', usn: 9),
    ];
    final reviewed = await repo.reviewNotebookConflict(session, source);
    remoteBooks[1] = remote(id: newParent, title: 'Changed parent', usn: 11);
    await expectLater(
      repo.resolveNotebookConflict(session, reviewed, keepLocal: false),
      throwsStateError,
    );
    expect((await db.notebooks(account.cacheKey)).length, 3);
  });
  test(
    'local parent cycle rejects remote move without deleting any rows',
    () async {
      // Remote child was moved to root, while the local child still points at source.
      await db.editLocalNotebook(
        account.cacheKey,
        child,
        title: 'Pending child',
      );
      remoteBooks = [
        remote(parent: child),
        remote(id: child, usn: 9, parent: ''),
        book(target, ''),
      ];
      final reviewed = await repo.reviewNotebookConflict(session, source);
      await expectLater(
        repo.resolveNotebookConflict(session, reviewed, keepLocal: false),
        throwsStateError,
      );
      expect((await db.notebooks(account.cacheKey)).length, 3);
      expect((await db.dirtyNotebooks(account.cacheKey)).length, 2);
    },
  );
  for (final mode in ['deleted', 'missing', 'duplicate', 'malformed']) {
    test(
      'unavailable or malformed remote snapshot preserves local: $mode',
      () async {
        remoteBooks = switch (mode) {
          'deleted' => [remote(deleted: true)],
          'missing' => [],
          'duplicate' => [remote(), remote()],
          _ => [remote(parent: 'invalid')],
        };
        await expectLater(
          repo.reviewNotebookConflict(session, source),
          throwsStateError,
        );
        expect(
          (await db.dirtyNotebooks(account.cacheKey)).single.title,
          'Local',
        );
      },
    );
  }
  test(
    'failed transaction rolls back inserted ancestors and target metadata',
    () async {
      const newParent = '507f1f77bcf86cd799439099';
      remoteBooks = [
        remote(parent: newParent),
        remote(id: newParent, title: 'Parent', usn: 9),
      ];
      final reviewed = await repo.reviewNotebookConflict(session, source);
      await db.raw.execute(
        "CREATE TRIGGER fail_resolution BEFORE UPDATE ON notebooks BEGIN SELECT RAISE(ABORT, 'disk'); END",
      );
      await expectLater(
        repo.resolveNotebookConflict(session, reviewed, keepLocal: false),
        throwsA(anything),
      );
      expect((await db.notebooks(account.cacheKey)).length, 3);
      expect((await db.dirtyNotebooks(account.cacheKey)).single.title, 'Local');
      expect(await db.lastSyncUsn(account.cacheKey), 5);
    },
  );
  for (final conflictAgain in [false, true]) {
    test(
      'next sync uses reviewed USN and still detects later conflicts: $conflictAgain',
      () async {
        final reviewed = await repo.reviewNotebookConflict(session, source);
        await repo.resolveNotebookConflict(session, reviewed, keepLocal: true);
        var writes = 0;
        final api = Api2Client(
          httpClient: MockClient((request) async {
            if (request.url.path == '/api2/user/getSyncState') {
              return http.Response('{"LastSyncUsn":100}', 200);
            }
            if (request.url.path == '/api2/client/notebook/update') {
              writes++;
              expect(request.bodyFields['usn'], '10');
              expect(request.bodyFields['title'], 'Local');
              if (conflictAgain) {
                return http.Response('{"Ok":false,"Msg":"conflict"}', 200);
              }
              return http.Response(
                jsonEncode({
                  'NotebookId': source,
                  'Title': 'Local',
                  'ParentNotebookId': '',
                  'Seq': 4,
                  'Usn': 21,
                }),
                200,
              );
            }
            expect(request.url.path, '/api2/notebook/getSyncNotebooks');
            return http.Response(
              jsonEncode([
                {
                  'NotebookId': source,
                  'Title': 'New remote',
                  'ParentNotebookId': '',
                  'Seq': 7,
                  'Usn': 22,
                },
              ]),
              200,
            );
          }),
        );
        final upload = SyncCoordinator(
          api,
          db,
        ).uploadPending(account: account, token: 't');
        if (conflictAgain) {
          await expectLater(upload, throwsStateError);
          expect((await db.dirtyNotebooks(account.cacheKey)).single.usn, 10);
        } else {
          await upload;
          expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
          expect(
            (await db.notebooks(account.cacheKey))
                .firstWhere((n) => n.notebookId == source)
                .usn,
            21,
          );
        }
        expect(writes, 1);
        expect(await db.lastSyncUsn(account.cacheKey), 5);
      },
    );
  }
  test('remote reversal refreshes clean ancestors atomically without losing note bodies', () async {
    remoteBooks = [
      remote(parent: child),
      remote(id: child, usn: 9, parent: '', title: 'Moved parent'),
      book(target, ''),
    ];
    final note = await db.createLocalNote(
      account: account,
      notebookId: child,
      isMarkdown: true,
      content: 'Child draft',
    );
    final reviewed = await repo.reviewNotebookConflict(session, source);
    await repo.resolveNotebookConflict(session, reviewed, keepLocal: false);
    final books = await db.notebooks(account.cacheKey);
    expect(books.firstWhere((n) => n.notebookId == child).parentNotebookId, '');
    expect(
      books.firstWhere((n) => n.notebookId == source).parentNotebookId,
      child,
    );
    expect(
      (await db.dirtyNotes(account.cacheKey)).single.content,
      'Child draft',
    );
    expect(await db.pendingNoteIds(account.cacheKey), {note.noteId});
  });
}
