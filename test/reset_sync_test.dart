import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase db;
  late Note draft;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://notes.example.test/'),
    username: 'user',
    email: '',
    logo: '',
  );
  final other = Account(
    userId: 'other',
    server: Uri.parse('https://notes.example.test/'),
    username: 'other',
    email: '',
    logo: '',
  );
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: other,
      notebooks: [],
      notes: [
        Note.fromJson({'NoteId': 'other-note'}),
      ],
      tags: [],
      lastSyncUsn: 20,
    );
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 10,
    );
    draft = await db.createLocalNote(
      account: account,
      notebookId: 'local-book',
      isMarkdown: true,
    );
  });
  tearDown(() => db.raw.close());

  for (final mode in ['success', 'networkFailure', 'concurrentEdit']) {
    test('reset snapshot: $mode', () async {
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            expect(
              request.method,
              'GET',
            ); // Never upload discarded local drafts.
            if (request.url.path.endsWith('getSyncState')) {
              return http.Response(
                '{"LastSyncUsn":3}',
                200,
              ); // Server reset supported.
            }
            expect(request.url.queryParameters['afterUsn'], '0');
            if (request.url.path.endsWith('getSyncNotebooks')) {
              return http.Response(
                '[{"NotebookId":"server-book","Title":"Server","Usn":1}]',
                200,
              );
            }
            if (request.url.path.endsWith('getSyncNotesWithContent')) {
              return http.Response(
                jsonEncode([
                  {
                    'NoteId': 'server-note',
                    'NotebookId': 'server-book',
                    'Content': 'remote',
                    'Usn': 2,
                  },
                ]),
                200,
              );
            }
            if (mode == 'networkFailure') {
              return http.Response('{"Ok":false,"Msg":"offline"}', 503);
            }
            if (mode == 'concurrentEdit') {
              await db.saveEditedText(
                account.cacheKey,
                draft.noteId,
                'New edit',
                'Keep me',
              );
            }
            return http.Response('[{"Tag":"remote","Usn":3}]', 200);
          }),
        ),
        db,
      );
      final operation = sync.resetFromServer(
        account: account,
        token: 'test-token',
      );
      if (mode == 'success') {
        await operation;
        expect((await db.notes(account.cacheKey)).single.noteId, 'server-note');
        expect(
          (await db.notebooks(account.cacheKey)).single.notebookId,
          'server-book',
        );
        expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
        expect(await db.lastSyncUsn(account.cacheKey), 3);
      } else {
        await expectLater(
          operation,
          mode == 'concurrentEdit' ? throwsStateError : throwsException,
        );
        expect((await db.notes(account.cacheKey)).single.noteId, draft.noteId);
        expect(await db.notebooks(account.cacheKey), isEmpty);
        expect(await db.pendingNoteIds(account.cacheKey), {draft.noteId});
        expect(await db.lastSyncUsn(account.cacheKey), 10);
      }
      expect((await db.notes(other.cacheKey)).single.noteId, 'other-note');
      expect(await db.lastSyncUsn(other.cacheKey), 20);
    });
  }
}
