import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/notebook_tree.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

const source = '507f1f77bcf86cd799439011';
const child = '507f1f77bcf86cd799439012';
const target = '507f1f77bcf86cd799439013';
Notebook book(String id, String parent) => Notebook(
  notebookId: id,
  parentNotebookId: parent,
  title: id,
  sequence: 4,
  usn: 5,
  numberNotes: 0,
  isDeleted: false,
);

void main() {
  test(
    'targets reject original cyclic links and descendants, allow root repair',
    () {
      final books = [
        book(source, ''),
        book(child, source),
        book(target, ''),
        book('a', 'b'),
        book('b', 'a'),
        book('orphan', 'missing'),
      ];
      for (final id in [source, child, 'a', 'b', 'orphan', 'missing']) {
        expect(canMoveNotebook(books, source, id), isFalse);
      }
      expect(canMoveNotebook(books, source, target), isTrue);
      expect(canMoveNotebook(books, source, ''), isTrue);
      expect(canMoveNotebook(books, 'a', ''), isTrue);
      expect(canMoveNotebook(books, 'missing', ''), isFalse);
    },
  );

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  for (final mode in ['success', 'conflict', 'wrongParent']) {
    test('move with server IDs and USN: $mode', () async {
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final account = Account(
        userId: 'u',
        server: Uri.parse('https://notes.example.test/'),
        username: 'u',
        email: '',
        logo: '',
      );
      await db.replaceSnapshot(
        account: account,
        notebooks: [book(source, ''), book(child, source), book(target, '')],
        notes: [],
        tags: [],
        lastSyncUsn: 5,
      );
      var calls = 0;
      final api = Api2Client(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('getSyncState')) {
            return http.Response('{"LastSyncUsn":100}', 200);
          }
          calls++;
          expect(request.url.path, '/api2/client/notebook/update');
          expect(request.method, 'POST');
          expect(request.bodyFields['notebookId'], source);
          expect(request.bodyFields['title'], source);
          expect(request.bodyFields['seq'], '4');
          expect(request.bodyFields['usn'], calls == 1 ? '5' : '6');
          expect(
            request.bodyFields['parentNotebookId'],
            calls == 1 ? target : '',
          );
          if (mode == 'conflict') {
            return http.Response('{"Ok":false,"Msg":"conflict"}', 200);
          }
          return http.Response(
            jsonEncode({
              'NotebookId': source,
              'Title': source,
              'Seq': 4,
              'Usn': 5 + calls,
              'ParentNotebookId': mode == 'wrongParent'
                  ? ''
                  : request.bodyFields['parentNotebookId'],
            }),
            200,
          );
        }),
      );
      final repo = AuthRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
      );
      final session = StoredSession(account: account, token: 'test-token');
      for (final invalid in [source, child, 'missing']) {
        await expectLater(
          repo.moveNotebook(session, source, invalid),
          throwsFormatException,
        );
      }
      await repo.moveNotebook(session, source, ''); // No-op sends nothing.
      expect(calls, 0);
      if (mode == 'success') {
        await repo.moveNotebook(session, source, target);
        expect(
          (await db.notebooks(account.cacheKey))
              .firstWhere((b) => b.notebookId == source)
              .parentNotebookId,
          target,
        );
        await repo.moveNotebook(session, source, '');
        expect(calls, 2);
      } else {
        await expectLater(
          repo.moveNotebook(session, source, target),
          throwsException,
        );
      }
      final cached = await db.notebooks(account.cacheKey);
      expect(
        cached.firstWhere((b) => b.notebookId == source).parentNotebookId,
        '',
      );
      expect(
        cached.firstWhere((b) => b.notebookId == child).parentNotebookId,
        source,
      );
      expect(await db.lastSyncUsn(account.cacheKey), 5);
    });
  }
}
