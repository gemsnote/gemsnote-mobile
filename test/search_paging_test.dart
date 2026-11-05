import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_search_result.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/note_search_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class SearchRepository implements AuthRepository {
  SearchRepository(this.search, {this.open});
  final Future<Note?> Function(String)? open;
  @override
  Future<Note?> searchableNote(String accountId, String noteId) =>
      open!(noteId);
  final Future<List<Note>> Function(String, int) search;
  @override
  Future<List<NoteSearchResult>> searchNoteSummaries(
    String accountId,
    String query, {
    int limit = 50,
  }) async => (await search(query, limit))
      .map(
        (note) => NoteSearchResult(
          noteId: note.noteId,
          title: note.title,
          updatedTime: note.updatedTime,
          isMarkdown: note.isMarkdown,
        ),
      )
      .toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  test('search reaches beyond 100, matches literal characters and excludes trash/deleted', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    addTearDown(db.raw.close);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      tags: [],
      lastSyncUsn: 1,
      notes: [
        for (var i = 0; i < 125; i++)
          Note.fromJson({
            'NoteId': '$i',
            'Title': 'match $i',
            'Content': r'100% a_b C:\notes',
            'UpdatedTime': '2026-01-01',
          }),
        Note.fromJson({
          'NoteId': 'trash',
          'Title': 'match trash',
          'IsTrash': true,
        }),
        Note.fromJson({
          'NoteId': 'deleted',
          'Title': 'match deleted',
          'IsDeleted': true,
        }),
      ],
    );
    expect(await db.searchNotes(account.cacheKey, 'match'), hasLength(50));
    expect(
      await db.searchNotes(account.cacheKey, 'match', limit: 151),
      hasLength(125),
    );
    expect(await db.searchNotes('other', 'match', limit: 151), isEmpty);
    for (final query in ['%', '_', r'\']) {
      expect(
        await db.searchNotes(account.cacheKey, query, limit: 151),
        hasLength(125),
      );
    }
    expect(await db.searchNotes(account.cacheKey, 'a%b'), isEmpty);
    expect(await db.searchNotes(account.cacheKey, r'\missing'), isEmpty);
    await expectLater(
      db.searchNotes(account.cacheKey, 'match', limit: 0),
      throwsArgumentError,
    );
  });

  test(
    'summaries match bodies but opening reloads only a live account note',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final body = '${'大正文' * 100000}唯一关键词';
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        tags: [],
        lastSyncUsn: 1,
        notes: [
          Note.fromJson({'NoteId': 'large', 'Title': '标题', 'Content': body}),
        ],
      );
      final result = (await db.searchNoteSummaries(
        account.cacheKey,
        '唯一关键词',
      )).single;
      expect(result.noteId, 'large');
      expect(result.title, '标题');
      expect(await db.searchNoteSummaries('other', '唯一关键词'), isEmpty);
      expect(await db.searchableNote('other', result.noteId), isNull);
      expect(
        (await db.searchableNote(account.cacheKey, result.noteId))!.content,
        body,
      );
      await db.raw.update(
        'notes',
        {'content': '最新正文'},
        where: 'server_id = ?',
        whereArgs: ['large'],
      );
      expect(
        (await db.searchableNote(account.cacheKey, result.noteId))!.content,
        '最新正文',
      );
      await db.raw.update('notes', {'is_trash': 1});
      expect(await db.searchableNote(account.cacheKey, result.noteId), isNull);
      await db.raw.update('notes', {'is_trash': 0, 'local_is_deleted': 1});
      expect(await db.searchableNote(account.cacheKey, result.noteId), isNull);
    },
  );

  testWidgets('opening retries errors and ignores a result from an old query', (
    tester,
  ) async {
    var pending = Completer<Note?>();
    var calls = 0;
    final repo = SearchRepository(
      (query, limit) async => [
        Note.fromJson({'NoteId': query, 'Title': 'Result $query'}),
      ],
      open: (id) {
        calls++;
        return pending.future;
      },
    );
    Note? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened = await Navigator.of(context).push<Note>(
                MaterialPageRoute(
                  builder: (_) => NoteSearchPage(
                    repository: repo,
                    session: StoredSession(account: account, token: 't'),
                  ),
                ),
              );
            },
            child: const Text('Search'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Result old'));
    await tester.pump();
    await tester.tap(find.text('Result old'));
    expect(calls, 1);
    await tester.enterText(find.byType(TextField), 'new');
    pending.complete(Note.fromJson({'NoteId': 'old'}));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(opened, isNull);
    pending = Completer<Note?>();
    await tester.tap(find.text('Result new'));
    pending.completeError(StateError('database unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取笔记失败'), findsOneWidget);
    pending = Completer<Note?>();
    await tester.tap(find.text('Result new'));
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('笔记已删除'), findsOneWidget);
    pending = Completer<Note?>();
    await tester.tap(find.text('Result new'));
    pending.complete(Note.fromJson({'NoteId': 'new', 'Content': 'Fresh body'}));
    await tester.pumpAndSettle();
    expect(opened!.content, 'Fresh body');
    expect(find.byType(NoteSearchPage), findsNothing);
  });

  testWidgets('debounced search ignores stale responses and permits retry', (
    tester,
  ) async {
    final old = Completer<List<Note>>();
    var calls = 0;
    var fail = true;
    final repo = SearchRepository((query, limit) async {
      calls++;
      expect(limit, 51);
      if (query == 'old') return old.future;
      if (fail) throw StateError('database unavailable');
      return [
        Note.fromJson({'NoteId': 'new', 'Title': 'New result'}),
      ];
    });
    await tester.pumpWidget(
      MaterialApp(
        home: NoteSearchPage(
          repository: repo,
          session: StoredSession(account: account, token: 'test-token'),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索失败'), findsOneWidget);
    old.complete([
      Note.fromJson({'NoteId': 'old', 'Title': 'Old result'}),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Old result'), findsNothing);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('New result'), findsOneWidget);
    expect(calls, 3);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('New result'), findsNothing);
    expect(find.text('输入关键词开始搜索'), findsOneWidget);
  });

  testWidgets('load more refreshes a growing prefix without duplicating rows', (
    tester,
  ) async {
    final limits = <int>[];
    final repo = SearchRepository((query, limit) async {
      limits.add(limit);
      return List.generate(
        limit < 125 ? limit : 125,
        (i) => Note.fromJson({'NoteId': '$i', 'Title': 'Result $i'}),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: NoteSearchPage(
          repository: repo,
          session: StoredSession(account: account, token: 'test-token'),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'match');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        600,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
    }
    expect(limits, [51, 101, 151]);
    expect(find.text('已显示 125 篇'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });
}
