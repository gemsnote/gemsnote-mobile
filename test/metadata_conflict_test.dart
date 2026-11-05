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
  const id = '507f1f77bcf86cd799439011';
  final account = Account(
    userId: 'user',
    server: Uri.parse('https://notes.example.test/'),
    username: 'user',
    email: '',
    logo: '',
  );
  final local = Note.fromJson({
    'NoteId': id,
    'UserId': 'user',
    'NotebookId': 'old-book',
    'Title': 'local',
    'Content': 'same body',
    'Tags': ['local'],
    'Usn': 5,
    'IsMarkdown': true,
    'IsStar': false,
    'CreatedTime': '2025-01-01',
    'UpdatedTime': '2026-01-01',
  });
  late AppDatabase db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [local],
      tags: [],
      lastSyncUsn: 5,
    );
    await db.saveLocalNote(account.cacheKey, local);
  });
  tearDown(() => db.raw.close());

  for (final scenario in [
    'same body',
    'different body with image',
    'changed format with unknown files',
    'changed trash',
    'remote deleted',
    'remote changed during read',
    'local edit during read',
    'local deletion during read',
    'missing body',
    'missing metadata',
    'missing tags',
    'wrong owner',
    'network failure',
    'post conflict',
  ]) {
    test('metadata conflict: $scenario', () async {
      var reads = 0;
      var writes = 0;
      final api = Api2Client(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('getSyncState')) {
            return http.Response('{"LastSyncUsn":100}', 200);
          }
          expect(request.headers.values, contains('Bearer test-token'));
          if (request.method == 'POST') {
            writes++;
            expect(scenario, 'post conflict');
            return http.Response('{"Ok":false,"Msg":"conflict"}', 200);
          }
          final remote = <String, Object?>{
            'NoteId': id,
            'UserId': 'user',
            'NotebookId': 'remote-book',
            'Title': 'remote',
            'Tags': ['remote'],
            'Usn': 6,
            'IsMarkdown': true,
            'IsStar': true,
            'IsTrash': false,
            'IsDeleted': false,
            'CreatedTime': '2025-01-01',
            'UpdatedTime': '2026-02-01',
            'Files': [],
          };
          if (request.url.path == '/api2/note/getNote') {
            reads++;
            if (scenario == 'post conflict' && reads == 1) remote['Usn'] = 5;
            if (scenario == 'changed format with unknown files') {
              remote['IsMarkdown'] = false;
              remote.remove('Files');
            }
            if (scenario == 'changed trash') remote['IsTrash'] = true;
            if (scenario == 'remote deleted') remote['IsDeleted'] = true;
            if (scenario == 'missing metadata') remote.remove('Title');
            if (scenario == 'missing tags') remote.remove('Tags');
            if (scenario == 'wrong owner') remote['UserId'] = 'other';
            if (scenario == 'remote changed during read' && reads >= 3) {
              remote['Usn'] = 7;
            }
            return http.Response(jsonEncode(remote), 200);
          }
          expect(request.url.path, '/api2/note/getNoteContent');
          if (scenario == 'network failure') {
            return http.Response('failed', 503);
          }
          if (scenario == 'local edit during read') {
            await db.saveEditedText(
              account.cacheKey,
              id,
              'latest edit',
              'new body',
            );
          }
          if (scenario == 'local deletion during read') {
            await db.saveLocalNote(
              account.cacheKey,
              local.copyWith(isTrash: true),
            );
            await db.deleteLocalTrash(account.cacheKey, id);
          }
          return http.Response(
            jsonEncode({
              'NoteId': id,
              'UserId': scenario == 'wrong owner' ? 'other' : 'user',
              if (scenario != 'missing body')
                'Content': scenario == 'different body with image'
                    ? 'remote ![image](/image.png)'
                    : 'same body',
            }),
            200,
          );
        }),
      );
      final sync = SyncCoordinator(api, db);
      final operation = sync.uploadPending(
        account: account,
        token: 'test-token',
      );
      if (scenario == 'same body' || scenario == 'post conflict') {
        await operation;
        expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
        final resolved = (await db.notes(account.cacheKey)).single;
        expect(resolved.title, 'remote');
        expect(resolved.tags, ['remote']);
        expect(resolved.notebookId, 'remote-book');
        expect(resolved.isStarred, isTrue);
        expect(resolved.usn, 6);
        expect(resolved.content, local.content);
        expect(resolved.updatedTime, '2026-02-01');
        // No duplicate note and no unnecessary write on a second upload.
        await sync.uploadPending(account: account, token: 'test-token');
      } else {
        await expectLater(operation, throwsA(anything));
        final pending = (await db.dirtyNotes(account.cacheKey)).single;
        expect(pending.noteId, id);
        expect(pending.usn, 5);
        expect(
          pending.content,
          scenario == 'local edit during read' ? 'new body' : local.content,
        );
        expect(pending.isDeleted, scenario == 'local deletion during read');
      }
      expect(writes, scenario == 'post conflict' ? 1 : 0);
      expect(await db.lastSyncUsn(account.cacheKey), 5);
      expect(await db.raw.query('notes'), hasLength(1));
    });
  }
}
