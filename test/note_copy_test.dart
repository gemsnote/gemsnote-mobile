import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/note_reader_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://notes.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  final source = Note.fromJson({
    'NoteId': 'source',
    'UserId': 'u',
    'NotebookId': 'old',
    'Title': '标题',
    'Content': '# 正文',
    'Tags': ['标签'],
    'Usn': 7,
    'IsMarkdown': true,
    'IsStar': true,
    'CreatedTime': '2020-01-01',
    'UpdatedTime': '2020-01-02',
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
      notebooks: [
        Notebook.fromJson({'NotebookId': 'old', 'Title': 'Old'}),
        Notebook.fromJson({'NotebookId': 'target', 'Title': 'Target'}),
      ],
      notes: [source],
      tags: [],
      lastSyncUsn: 7,
    );
  });
  tearDown(() => db.raw.close());

  test('copy atomically preserves content and metadata, marks new, leaves source untouched', () async {
    final copy = await db.copyLocalNote(
      account: account,
      source: source,
      notebookId: 'target',
      filesConfirmedEmpty: true,
    );
    expect(copy.noteId, matches(RegExp(r'^[a-f0-9]{24}$')));
    expect(copy.title, '标题（副本）');
    expect(copy.content, source.content);
    expect(copy.tags, source.tags);
    expect(copy.isStarred, true);
    expect(copy.isMarkdown, true);
    expect(copy.usn, 0);
    expect(copy.createdTime, isNot(source.createdTime));
    expect(await db.pendingNoteIds(account.cacheKey), {copy.noteId});
    final row = (await db.raw.query(
      'notes',
      where: 'server_id = ?',
      whereArgs: [copy.noteId],
    )).single;
    expect(row['local_is_new'], 1);
    expect(
      (await db.notebooks(account.cacheKey))
          .firstWhere((b) => b.notebookId == 'target')
          .numberNotes,
      1,
    );
    expect(
      (await db.notes(account.cacheKey))
          .firstWhere((n) => n.noteId == source.noteId)
          .title,
      source.title,
    );
    expect(await db.lastSyncUsn(account.cacheKey), 7);
  });
  test('same notebook can contain a copy', () async {
    await db.copyLocalNote(
      account: account,
      source: source,
      notebookId: 'old',
      filesConfirmedEmpty: true,
    );
    expect((await db.notes(account.cacheKey, notebookId: 'old')).length, 2);
  });
  test(
    'cached attachments block copying even after an empty server reply',
    () async {
      await db.replaceNoteFiles(account.cacheKey, source.noteId, [
        NoteFile(
          id: '507f1f77bcf86cd799439011',
          title: 'file',
          type: 'txt',
          isAttachment: true,
        ),
      ]);
      await expectLater(
        db.copyLocalNote(
          account: account,
          source: source,
          notebookId: 'target',
          filesConfirmedEmpty: true,
        ),
        throwsStateError,
      );
      expect((await db.notes(account.cacheKey)).length, 1);
    },
  );
  test('basic HTML is preserved without conversion', () async {
    final html = source.copyWith(
      content: '<p><b>正文</b></p>',
      isMarkdown: false,
    );
    await db.saveLocalNote(account.cacheKey, html);
    final copy = await db.copyLocalNote(
      account: account,
      source: html,
      notebookId: 'target',
      filesConfirmedEmpty: true,
    );
    expect(copy.content, html.content);
    expect(copy.isMarkdown, false);
  });
  test('unknown files, invalid target, stale snapshot and foreign owner leave no copy', () async {
    for (final candidate in [
      source,
      source.copyWith(title: 'stale'),
      source.copyWith(userId: 'other'),
    ]) {
      await expectLater(
        db.copyLocalNote(
          account: account,
          source: candidate,
          notebookId: 'target',
          filesConfirmedEmpty: false,
        ),
        throwsStateError,
      );
    }
    await expectLater(
      db.copyLocalNote(
        account: account,
        source: source,
        notebookId: 'missing',
        filesConfirmedEmpty: true,
      ),
      throwsStateError,
    );
    expect((await db.notes(account.cacheKey)).length, 1);
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
  });
  test('unsupported body is never silently stripped', () async {
    final changed = source.copyWith(content: '![image](/image)');
    await db.saveLocalNote(account.cacheKey, changed);
    await expectLater(
      db.copyLocalNote(
        account: account,
        source: changed,
        notebookId: 'target',
        filesConfirmedEmpty: true,
      ),
      throwsStateError,
    );
    expect((await db.notes(account.cacheKey)).single.content, changed.content);
  });
  test('repository checks stable server snapshot and refuses unavailable originals', () async {
    var mode = 'empty';
    var calls = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        calls++;
        expect(request.url.path, startsWith('/api2/'));
        if (request.url.path == '/api2/note/getNoteContent') {
          return http.Response(
            jsonEncode({
              'NoteId': source.noteId,
              'UserId': 'u',
              'Content': source.content,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/api2/file/getAttach') {
          return http.Response('unavailable', 503);
        }
        if (mode == 'offline') return http.Response('offline', 503);
        return http.Response(
          jsonEncode({
            'NoteId': source.noteId,
            'UserId': 'u',
            'NotebookId': source.notebookId,
            'Title': source.title,
            'Usn': source.usn,
            'Tags': source.tags,
            'IsMarkdown': true,
            'IsStar': true,
            'IsTrash': false,
            'IsDeleted': false,
            'CreatedTime': source.createdTime,
            'UpdatedTime': source.updatedTime,
            'Files': mode == 'empty'
                ? []
                : [
                    {
                      'FileId': '507f1f77bcf86cd799439011',
                      'IsAttach': true,
                      'Title': 'a.txt',
                      'Type': 'txt',
                    },
                  ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    final session = StoredSession(account: account, token: 'test');
    await repo.copyNote(session, source, 'target');
    mode = 'attached';
    await expectLater(
      repo.copyNote(session, source, 'target'),
      throwsA(isA<Object>()),
    );
    mode = 'offline';
    await expectLater(
      repo.copyNote(session, source, 'target'),
      throwsA(isA<Object>()),
    );
    expect(calls, greaterThan(3));
    expect((await db.notes(account.cacheKey)).length, 2);
    final beforeLocalCopy = calls;
    final local = await db.createLocalNote(
      account: account,
      notebookId: 'old',
      isMarkdown: true,
      content: 'offline',
    );
    await repo.copyNote(session, local, 'target');
    expect(calls, beforeLocalCopy);
  });
  testWidgets('copy cancellation keeps reader open and trash offers no copy', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NoteReaderPage(
          note: source,
          onCopy: () async {
            calls++;
            return false;
          },
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到笔记本'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(NoteReaderPage), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: NoteReaderPage(
          note: source.copyWith(isTrash: true),
          onCopy: () async => true,
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('复制到笔记本'), findsNothing);
  });
}
