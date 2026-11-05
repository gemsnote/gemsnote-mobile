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
  late AppDatabase db;
  late Directory temp;
  late String path;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://notes.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    temp = await Directory.systemTemp.createTemp('offline-books-');
    path = '${temp.path}/db';
    db = await AppDatabase.open(databasePath: path);
    await db.replaceSnapshot(
      account: account,
      notebooks: [book(source, ''), book(child, source), book(target, '')],
      notes: [],
      tags: [],
      lastSyncUsn: 5,
    );
  });
  tearDown(() async {
    await db.raw.close();
    await temp.delete(recursive: true);
  });
  Notebook remote(Notebook local, {String? title, int usn = 6}) => Notebook(
    notebookId: local.notebookId,
    parentNotebookId: local.parentNotebookId,
    title: title ?? local.title,
    sequence: local.sequence,
    usn: usn,
    numberNotes: 0,
    isDeleted: false,
  );
  test(
    'offline rename and move survive reopen; no-op and invalid trees stay safe',
    () async {
      await db.editLocalNotebook(account.cacheKey, source, title: source);
      expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
      await db.editLocalNotebook(account.cacheKey, source, title: 'Offline');
      await db.editLocalNotebook(account.cacheKey, source, parentId: target);
      await expectLater(
        db.editLocalNotebook(account.cacheKey, source, parentId: child),
        throwsFormatException,
      );
      await expectLater(
        db.editLocalNotebook(account.cacheKey, source, parentId: 'missing'),
        throwsFormatException,
      );
      await expectLater(
        db.editLocalNotebook('other', source, title: 'Wrong'),
        throwsStateError,
      );
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      final pending = (await db.dirtyNotebooks(account.cacheKey)).single;
      expect(pending.title, 'Offline');
      expect(pending.parentNotebookId, target);
      expect(pending.usn, 5);
      expect(await db.lastSyncUsn(account.cacheKey), 5);
      final all = await db.notebooks(account.cacheKey);
      expect(
        all.firstWhere((n) => n.notebookId == child).parentNotebookId,
        source,
      );
    },
  );
  test(
    'ack keeps edits made while upload waited and updates base USN',
    () async {
      await db.editLocalNotebook(account.cacheKey, source, title: 'first');
      final first = (await db.dirtyNotebooks(account.cacheKey)).single;
      await db.editLocalNotebook(account.cacheKey, source, title: 'second');
      await db.markNotebookUploaded(account.cacheKey, first, remote(first));
      final second = (await db.dirtyNotebooks(account.cacheKey)).single;
      expect(second.title, 'second');
      expect(second.usn, 6);
      await db.markNotebookUploaded(
        account.cacheKey,
        second,
        remote(second, usn: 7),
      );
      expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
      expect(await db.lastSyncUsn(account.cacheKey), 5);
    },
  );
  test(
    'merge, cache and reset cannot silently overwrite dirty notebook',
    () async {
      final snapshot = await db.noteSnapshotFingerprint(account.cacheKey);
      await db.editLocalNotebook(account.cacheKey, source, title: 'offline');
      await expectLater(
        db.mergeChanges(
          account: account,
          notebooks: [book(source, '')],
          notes: [],
          tags: [],
          lastSyncUsn: 8,
        ),
        throwsStateError,
      );
      await expectLater(
        db.cacheNotebook(account.cacheKey, book(source, '')),
        throwsStateError,
      );
      await expectLater(
        db.replaceSnapshot(
          account: account,
          notebooks: [],
          notes: [],
          tags: [],
          lastSyncUsn: 8,
        ),
        throwsStateError,
      );
      await expectLater(
        db.replaceSnapshot(
          account: account,
          notebooks: [],
          notes: [],
          tags: [],
          lastSyncUsn: 8,
          expectedNoteSnapshot: snapshot,
        ),
        throwsStateError,
      );
      expect(
        (await db.dirtyNotebooks(account.cacheKey)).single.title,
        'offline',
      );
      expect(await db.lastSyncUsn(account.cacheKey), 5);
      final approved = await db.noteSnapshotFingerprint(account.cacheKey);
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 8,
        expectedNoteSnapshot: approved,
      );
      expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
    },
  );
  test('v8 upgrade preserves notes, notebook IDs and cursor', () async {
    final note = await db.createLocalNote(
      account: account,
      notebookId: source,
      isMarkdown: true,
      content: 'draft',
    );
    await db.raw.execute('ALTER TABLE notebooks DROP COLUMN is_dirty');
    await db.raw.setVersion(8);
    await db.raw.close();
    db = await AppDatabase.open(databasePath: path);
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
    expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
    expect(await db.pendingNoteIds(account.cacheKey), {note.noteId});
    expect((await db.notebooks(account.cacheKey)).length, 3);
    expect(await db.lastSyncUsn(account.cacheKey), 5);
  });
  for (final mode in ['success', 'lostResponse', 'conflict', 'concurrent']) {
    test('API2 upload of offline notebook: $mode', () async {
      await db.editLocalNotebook(account.cacheKey, source, title: 'renamed');
      var calls = 0;
      final api = Api2Client(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('getSyncState')) {
            return http.Response('{"LastSyncUsn":100}', 200);
          }
          calls++;
          if (request.url.path == '/api2/client/notebook/update') {
            expect(request.bodyFields['usn'], '5');
            expect(request.bodyFields['title'], 'renamed');
            if (mode == 'concurrent') {
              await db.editLocalNotebook(
                account.cacheKey,
                source,
                title: 'newer',
              );
            }
            if (mode == 'lostResponse' || mode == 'conflict') {
              return http.Response('{"Ok":false,"Msg":"conflict"}', 200);
            }
            return http.Response(
              jsonEncode({
                'NotebookId': source,
                'Title': 'renamed',
                'ParentNotebookId': '',
                'Seq': 4,
                'Usn': 6,
              }),
              200,
            );
          }
          expect(request.url.path, '/api2/notebook/getSyncNotebooks');
          return http.Response(
            jsonEncode([
              {
                'NotebookId': source,
                'Title': mode == 'lostResponse' ? 'renamed' : 'remote edit',
                'ParentNotebookId': '',
                'Seq': 4,
                'Usn': 6,
              },
            ]),
            200,
          );
        }),
      );
      final sync = SyncCoordinator(api, db);
      final future = sync.uploadPending(account: account, token: 't');
      if (mode == 'conflict' || mode == 'concurrent') {
        await expectLater(future, throwsStateError);
        expect(
          (await db.dirtyNotebooks(account.cacheKey)).single.title,
          mode == 'concurrent' ? 'newer' : 'renamed',
        );
      } else {
        await future;
        expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
      }
      expect(calls, mode == 'lostResponse' || mode == 'conflict' ? 2 : 1);
      expect(await db.lastSyncUsn(account.cacheKey), 5);
    });
  }
  test(
    'parent reversal uploads detached child before its former parent',
    () async {
      await db.editLocalNotebook(account.cacheKey, child, parentId: '');
      await db.editLocalNotebook(account.cacheKey, source, parentId: child);
      final order = <String>[];
      final api = Api2Client(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('getSyncState')) {
            return http.Response('{"LastSyncUsn":100}', 200);
          }
          expect(request.url.path, '/api2/client/notebook/update');
          final fields = request.bodyFields;
          order.add(fields['notebookId']!);
          return http.Response(
            jsonEncode({
              'NotebookId': fields['notebookId'],
              'Title': fields['title'],
              'ParentNotebookId': fields['parentNotebookId'],
              'Seq': 4,
              'Usn': 5 + order.length,
            }),
            200,
          );
        }),
      );
      await SyncCoordinator(
        api,
        db,
      ).uploadPending(account: account, token: 't');
      expect(order, [child, source]);
      expect(await db.dirtyNotebooks(account.cacheKey), isEmpty);
    },
  );

  test(
    'logout refuses pending notebook unless explicitly preserving it',
    () async {
      final api = Api2Client(
        httpClient: MockClient((_) => throw StateError('offline')),
      );
      final sessions = MemorySessions();
      await sessions.write(account.cacheKey, 't');
      final repo = AuthRepository(api, db, sessions, SyncCoordinator(api, db));
      final session = StoredSession(account: account, token: 't');
      await repo.queueNotebookRename(session, source, 'offline');
      await expectLater(repo.logout(session), throwsStateError);
      await expectLater(repo.prepareLogout(session), throwsA(anything));
      expect(
        (await db.dirtyNotebooks(account.cacheKey)).single.title,
        'offline',
      );
      await repo.logout(session, discardSessionWithPendingChanges: true);
      expect(sessions.values, isEmpty);
      expect(
        (await db.dirtyNotebooks(account.cacheKey)).single.title,
        'offline',
      );
    },
  );
}
