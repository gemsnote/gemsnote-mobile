import 'dart:async';
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

import 'support/created_note.dart';

void main() {
  late AppDatabase db;
  late Note draft;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://notes.example.test/'),
    username: 'u',
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
    for (final owner in [account, other]) {
      await db.replaceSnapshot(
        account: owner,
        notebooks: [],
        notes: [
          Note.fromJson({'NoteId': 'retained', 'Content': 'cached', 'Usn': 2}),
        ],
        tags: [],
        lastSyncUsn: 10,
      );
    }
    draft = await db.createLocalNote(
      account: account,
      notebookId: 'book',
      isMarkdown: true,
    );
  });
  tearDown(() => db.raw.close());

  for (final mode in [
    'success',
    'uploadFailure',
    'downloadFailure',
    'concurrentEdit',
    'serverReset',
  ]) {
    test('full merge uploads first and protects data: $mode', () async {
      final paths = <String>[];
      final progress = <SyncProgress>[];
      Map<String, Object?>? created;
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            final path = request.url.path;
            paths.add(path);
            if (path.endsWith('/add')) {
              expect(request.method, 'POST');
              if (mode == 'uploadFailure') {
                return http.Response('{"Ok":false,"Msg":"offline"}', 503);
              }
              final body = Uri.splitQueryString(request.body);
              expect(body['ClientNoteId'], draft.noteId);
              created = createdNote(body, usn: 11);
              return http.Response(
                jsonEncode({'NoteId': draft.noteId, 'Usn': 11}),
                200,
              );
            }
            if (path.endsWith('getNote') || path.endsWith('getNoteContent')) {
              return http.Response(jsonEncode(created), 200);
            }
            expect(paths.first, '/api2/user/getSyncState');
            if (path.endsWith('getSyncState')) {
              return http.Response(
                jsonEncode({'LastSyncUsn': mode == 'serverReset' ? 1 : 20}),
                200,
              );
            }
            expect(request.url.queryParameters['afterUsn'], '0');
            if (path.endsWith('getSyncNotebooks')) {
              return http.Response(
                '[{"NotebookId":"book","Title":"Recovered book","Usn":1}]',
                200,
              );
            }
            if (path.endsWith('getSyncNotesWithContent')) {
              return http.Response(
                jsonEncode([
                  {
                    'NoteId': 'recovered',
                    'NotebookId': 'book',
                    'Content': 'remote body',
                    'Usn': 3,
                  },
                  {
                    'NoteId': draft.noteId,
                    'NotebookId': 'book',
                    'Content': '',
                    'Usn': 11,
                  },
                ]),
                200,
              );
            }
            if (mode == 'downloadFailure') {
              return http.Response('{"Ok":false,"Msg":"offline"}', 503);
            }
            if (mode == 'concurrentEdit') {
              await db.saveEditedText(
                account.cacheKey,
                draft.noteId,
                'new edit',
                'must survive',
              );
            }
            return http.Response('[]', 200);
          }),
        ),
        db,
      );
      final operation = sync.synchronizeFull(
        account: account,
        token: 'test',
        onProgress: progress.add,
      );
      if (mode == 'success') {
        await operation;
        expect(
          (await db.notes(account.cacheKey)).map((n) => n.noteId),
          containsAll(['retained', 'recovered', draft.noteId]),
        );
        expect(
          (await db.notebooks(account.cacheKey)).single.title,
          'Recovered book',
        );
        expect(await db.lastSyncUsn(account.cacheKey), 20);
        expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
        expect(progress.first.stage, SyncStage.uploading);
        expect(progress.last.stage, SyncStage.saving);
      } else {
        await expectLater(
          operation,
          mode == 'concurrentEdit' || mode == 'serverReset'
              ? throwsStateError
              : throwsException,
        );
        expect(
          (await db.notes(account.cacheKey)).map((n) => n.noteId),
          isNot(contains('recovered')),
        );
        expect(await db.notebooks(account.cacheKey), isEmpty);
        expect(await db.lastSyncUsn(account.cacheKey), 10);
        if (mode == 'uploadFailure') {
          expect(paths, ['/api2/user/getSyncState', '/api2/client/note/add']);
        }
        if (mode == 'uploadFailure' || mode == 'concurrentEdit') {
          expect(
            await db.pendingNoteIds(account.cacheKey),
            contains(draft.noteId),
          );
        }
        if (mode == 'concurrentEdit') {
          expect(
            (await db.notes(account.cacheKey))
                .firstWhere((n) => n.noteId == draft.noteId)
                .content,
            'must survive',
          );
        }
      }
      expect((await db.notes(other.cacheKey)).single.noteId, 'retained');
      expect(await db.lastSyncUsn(other.cacheKey), 10);
    });
  }

  test(
    'duplicate full sync reuses task; reset cannot run concurrently',
    () async {
      final gate = Completer<void>();
      var uploads = 0;
      Map<String, Object?>? created;
      final sync = SyncCoordinator(
        Api2Client(
          httpClient: MockClient((request) async {
            if (request.method == 'POST') {
              uploads++;
              await gate.future;
              created = createdNote(
                Uri.splitQueryString(request.body),
                usn: 11,
              );
              return http.Response(
                jsonEncode({'NoteId': draft.noteId, 'Usn': 11}),
                200,
              );
            }
            if (request.url.path.endsWith('getNote') ||
                request.url.path.endsWith('getNoteContent')) {
              return http.Response(jsonEncode(created), 200);
            }
            if (request.url.path.endsWith('getSyncState')) {
              return http.Response('{"LastSyncUsn":20}', 200);
            }
            return http.Response('[]', 200);
          }),
        ),
        db,
      );
      final first = sync.synchronizeFull(account: account, token: 'test');
      expect(
        identical(first, sync.synchronizeFull(account: account, token: 'test')),
        isTrue,
      );
      await expectLater(
        sync.resetFromServer(account: account, token: 'test'),
        throwsStateError,
      );
      gate.complete();
      await first;
      expect(uploads, 1);
      await sync.synchronizeFull(account: account, token: 'test');
      expect(uploads, 1);
    },
  );
}
