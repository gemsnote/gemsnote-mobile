import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/created_note.dart';

void main() {
  const id = '507f1f77bcf86cd799439011';
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  late AppDatabase db;
  final local = Note.fromJson({
    'NoteId': id,
    'UserId': 'u',
    'NotebookId': 'book',
    'Title': 'local',
    'Content': '# Local body',
    'IsMarkdown': true,
    'Tags': ['local'],
    'Usn': 5,
    'CreatedTime': '2025-01-01',
    'UpdatedTime': '2026-01-01',
  });
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

  for (final localMarkdown in [true, false]) {
    for (final resourceInLocal in [true, false]) {
      test(
        'format conflict preserves resources: MD=$localMarkdown local=$resourceInLocal',
        () async {
          String resource(bool markdown) =>
              markdown ? '![image](/files/image)' : '<img src="/files/image">';
          final pending = local.copyWith(
            isMarkdown: localMarkdown,
            content: resourceInLocal ? resource(localMarkdown) : 'Plain text',
          );
          await db.saveLocalNote(account.cacheKey, pending);
          final remote = pending.copyWith(
            isMarkdown: !localMarkdown,
            content: resourceInLocal ? 'Remote text' : resource(!localMarkdown),
            usn: 6,
          );
          await expectLater(
            db.resolveNoteConflict(
              account.cacheKey,
              pending,
              remote,
              filesConfirmedEmpty: true,
            ),
            throwsStateError,
          );
          final retained = (await db.dirtyNotes(account.cacheKey)).single;
          expect(retained.noteId, id);
          expect(retained.content, pending.content);
          expect(retained.isMarkdown, localMarkdown);
          expect(retained.usn, 5);
          expect(await db.notes(account.cacheKey), hasLength(1));
          expect(await db.lastSyncUsn(account.cacheKey), 5);
        },
      );
    }
  }

  for (final mode in [
    'success',
    'lostCopyResponse',
    'remoteFiles',
    'unknownFiles',
    'localFiles',
    'localEdit',
    'html',
    'htmlLostCopyResponse',
    'htmlResource',
    'htmlLocalResource',
    'htmlLocalFiles',
    'htmlLocalEdit',
    'htmlToMarkdown',
    'htmlToMarkdownSameBody',
    'markdownToHtml',
    'markdownToHtmlSameBody',
    'htmlToMarkdownLostCopyResponse',
    'localImage',
  ]) {
    test('body conflict preserves local data: $mode', () async {
      final rich = mode.startsWith('html');
      final changedFormat = mode.contains('To');
      final remoteMarkdown = changedFormat ? rich : !rich;
      final sameBody = mode.endsWith('SameBody');
      final localBody = sameBody
          ? 'Same source, different format'
          : mode == 'htmlLocalResource'
          ? '<p><img src="/files/local"></p>'
          : rich
          ? '<p><strong>Local &amp; body</strong></p>'
          : local.content;
      final remoteBody = sameBody
          ? localBody
          : remoteMarkdown
          ? 'Remote body'
          : '<div><em>Remote body</em></div>';
      var failCopy =
          mode == 'lostCopyResponse' || mode.endsWith('LostCopyResponse');
      final uploadedIds = <String>[];
      if (mode == 'localFiles' || mode == 'htmlLocalFiles') {
        await db.replaceNoteFiles(account.cacheKey, id, [
          const NoteFile(
            id: 'file',
            title: 'file',
            type: 'text',
            isAttachment: true,
          ),
        ]);
      }
      if (mode == 'localImage') {
        await db.saveEditedText(
          account.cacheKey,
          id,
          'local',
          '![img](/api/file/getImage?id=file)',
        );
      }
      if (rich || sameBody) {
        await db.saveLocalNote(
          account.cacheKey,
          local.copyWith(isMarkdown: !rich, content: localBody),
        );
      }
      Map<String, Object?>? created;
      final api = Api2Client(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('getSyncState')) {
            return http.Response('{"LastSyncUsn":100}', 200);
          }
          if (request.method == 'POST') {
            expect(request.url.path, '/api2/client/note/add');
            final fields = Uri.splitQueryString(request.body);
            final copyId = fields['ClientNoteId']!;
            uploadedIds.add(copyId);
            expect(copyId, isNot(id));
            expect(fields['Content'], localBody);
            expect(fields['IsMarkdown'], '${!rich}');
            expect(fields['Title'], 'local（本地冲突副本）');
            created ??= createdNote(fields, usn: 7);
            if (failCopy) throw const FormatException('connection lost');
            return http.Response(jsonEncode({'NoteId': copyId, 'Usn': 7}), 200);
          }
          if (created != null &&
              request.url.queryParameters['noteId'] == created!['NoteId']) {
            return http.Response(
              jsonEncode(created),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.path.endsWith('getNote')) {
            return http.Response(
              jsonEncode({
                'NoteId': id,
                'UserId': 'u',
                'NotebookId': 'remote-book',
                'Title': 'remote',
                'Content': 'ignored',
                'IsMarkdown': remoteMarkdown,
                'IsStar': true,
                'IsTrash': false,
                'IsDeleted': false,
                'Tags': ['remote'],
                'Usn': 6,
                'CreatedTime': '2025-01-01',
                'UpdatedTime': '2026-02-01',
                if (mode != 'unknownFiles')
                  'Files': mode == 'remoteFiles'
                      ? [
                          {'FileId': 'file'},
                        ]
                      : [],
              }),
              200,
            );
          }
          expect(request.url.path, '/api2/note/getNoteContent');
          if (mode == 'localEdit' || mode == 'htmlLocalEdit') {
            await db.saveEditedText(
              account.cacheKey,
              id,
              'new edit',
              'new local body',
            );
          }
          return http.Response(
            jsonEncode({
              'NoteId': id,
              'UserId': 'u',
              'Content': mode == 'htmlResource'
                  ? '<img src="/files/image">'
                  : remoteBody,
            }),
            200,
          );
        }),
      );
      final sync = SyncCoordinator(api, db);
      final task = sync.uploadPending(account: account, token: 'test');
      if (mode == 'success' ||
          changedFormat ||
          mode == 'lostCopyResponse' ||
          mode == 'html' ||
          mode == 'htmlLostCopyResponse') {
        if (failCopy) {
          await expectLater(task, throwsA(anything));
          final dirty = (await db.dirtyNotes(account.cacheKey)).single;
          expect(dirty.noteId, uploadedIds.single);
          expect(dirty.content, localBody);
          failCopy = false;
          await sync.uploadPending(account: account, token: 'test');
          expect(uploadedIds, [dirty.noteId, dirty.noteId]);
        } else {
          await task;
        }
        final notes = await db.notes(account.cacheKey);
        expect(notes, hasLength(2));
        final original = notes.firstWhere((n) => n.noteId == id);
        expect(original.title, 'remote');
        expect(original.content, remoteBody);
        expect(original.isMarkdown, remoteMarkdown);
        expect(original.tags, ['remote']);
        expect(original.notebookId, 'remote-book');
        final copy = notes.firstWhere((n) => n.noteId != id);
        expect(copy.content, localBody);
        expect(copy.isMarkdown, !rich);
        expect(copy.tags, local.tags);
        expect(copy.notebookId, local.notebookId);
        expect(copy.usn, 7);
        expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
        await sync.uploadPending(account: account, token: 'test');
        expect(await db.notes(account.cacheKey), hasLength(2));
      } else {
        await expectLater(task, throwsA(anything));
        expect(uploadedIds, isEmpty);
        expect(await db.notes(account.cacheKey), hasLength(1));
        expect(await db.pendingNoteIds(account.cacheKey), {id});
        if (mode == 'localEdit' || mode == 'htmlLocalEdit') {
          expect(
            (await db.notes(account.cacheKey)).single.content,
            'new local body',
          );
        }
        if (mode == 'localFiles' || mode == 'htmlLocalFiles') {
          expect(await db.cachedNoteFiles(account.cacheKey, id), hasLength(1));
        }
      }
      expect(await db.lastSyncUsn(account.cacheKey), 5);
    });
  }
}
