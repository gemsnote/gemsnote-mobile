import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/file_cache_usage.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/data/database/file_download_journal.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/workspace_page.dart';

import 'foreground_sync_test.dart' show ForegroundRepository;

class CacheRepository extends ForegroundRepository {
  DownloadQueueStatus restored = const DownloadQueueStatus();
  @override
  Future<DownloadQueueStatus> downloadQueueStatus(
    StoredSession session,
  ) async => restored;
  bool cacheEnabled = false;
  bool failRead = false;
  bool failWrite = false;
  Completer<void>? saveGate;
  int writes = 0;
  @override
  Future<bool> autoCacheFiles(StoredSession session) async {
    if (failRead) throw StateError('read');
    return cacheEnabled;
  }

  @override
  Future<void> setAutoCacheFiles(StoredSession session, bool enabled) async {
    writes++;
    await saveGate?.future;
    if (failWrite) throw StateError('write');
    cacheEnabled = enabled;
  }

  int fileLists = 0;
  final gate = Completer<List<NoteFile>>();
  @override
  Future<List<Note>> notes(
    String accountId, {
    String? notebookId,
    bool starredOnly = false,
    bool trashOnly = false,
  }) async => [
    Note.fromJson({'NoteId': 'n', 'Usn': 1}),
    Note.fromJson({'NoteId': 'new', 'Usn': 0}),
  ];
  @override
  Future<List<NoteFile>> noteFiles(
    StoredSession session,
    String id, {
    bool cachedOnly = false,
  }) {
    expect(id, 'n');
    fileLists++;
    return gate.future;
  }
}

void main() {
  testWidgets(
    'cache preference restores without download; read and write failures retry',
    (tester) async {
      final repo = CacheRepository()
        ..cacheEnabled = true
        ..restored = const DownloadQueueStatus(notes: 2, files: 5, failed: 1)
        ..failRead = true;
      final session = StoredSession(
        account: Account(
          userId: 'u',
          server: Uri.parse('https://notes.test'),
          username: 'u',
          email: '',
          logo: '',
        ),
        token: 't',
      );
      Future<void> mount() async {
        await tester.pumpWidget(
          MaterialApp(
            home: WorkspacePage(
              repository: repo,
              session: session,
              onSignedOut: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> menu() async {
        await tester.tap(find.byTooltip('账号菜单'));
        await tester.pumpAndSettle();
      }

      Finder toggle() => find.byWidgetPredicate(
        (w) => w is CheckedPopupMenuItem<String> && w.value == 'autoCache',
      );
      await mount();
      await menu();
      expect(
        tester.widget<CheckedPopupMenuItem<String>>(toggle()).enabled,
        false,
      );
      repo.failRead = false;
      await tester.tap(find.text('读取资源缓存设置失败，点击重试'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('资源缓存进度已恢复：2 篇笔记、5 个文件待处理，失败 1 项'),
        findsOneWidget,
      );
      expect(repo.calls, 0);
      await menu();
      expect(
        tester.widget<CheckedPopupMenuItem<String>>(toggle()).checked,
        true,
      );
      expect(repo.fileLists, 0);
      repo.failWrite = true;
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(find.text('保存资源缓存设置失败，仍使用原设置，请重试'), findsOneWidget);
      expect(repo.cacheEnabled, true);
      repo.failWrite = false;
      repo.saveGate = Completer<void>();
      await menu();
      expect(
        tester.widget<CheckedPopupMenuItem<String>>(toggle()).checked,
        true,
      );
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      await menu();
      expect(
        tester.widget<CheckedPopupMenuItem<String>>(toggle()).enabled,
        false,
      );
      expect(repo.writes, 2);
      repo.saveGate!.complete();
      await tester.tapAt(const Offset(10, 500));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await mount();
      await menu();
      expect(
        tester.widget<CheckedPopupMenuItem<String>>(toggle()).checked,
        false,
      );
      expect(repo.fileLists, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cache management waits for running queue before measuring and clearing',
    (tester) async {
      final repo = ManagedCacheRepository();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(
              account: Account(
                userId: 'u',
                server: Uri.parse('https://notes.test'),
                username: 'u',
                email: '',
                logo: '',
              ),
              token: 't',
            ),
            onSignedOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> choose(String value) async {
        await tester.tap(find.byTooltip('账号菜单'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is PopupMenuItem<String> && w.value == value,
          ),
        );
        await tester.pump();
      }

      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CheckedPopupMenuItem<String> && w.value == 'autoCache',
        ),
      );
      await tester.pumpAndSettle();
      await choose('cacheFiles');
      await tester.pumpAndSettle();
      expect(repo.fileLists, 1);
      await choose('manageCache');
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.measures, 0);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      repo.gate.complete([]);
      await tester.pumpAndSettle();
      expect(repo.measures, 1);
      expect(repo.clears, 0);
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(repo.clears, 1);
      expect(find.text('离线资源缓存已清理'), findsOneWidget);
    },
  );

  testWidgets(
    'opt-in caching starts after sync closes; failure is separate from dirty status',
    (tester) async {
      final repo = CacheRepository();
      final session = StoredSession(
        account: Account(
          userId: 'u',
          server: Uri.parse('https://notes.test'),
          username: 'u',
          email: '',
          logo: '',
        ),
        token: 'test',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: session,
            onSignedOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.fileLists, 0);
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CheckedPopupMenuItem<String> && w.value == 'autoCache',
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.fileLists, 0);
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即同步').first);
      await tester.pumpAndSettle();
      expect(repo.calls, 1);
      expect(repo.fileLists, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(repo.dirty, false);
      expect(find.textContaining('正在准备离线资源缓存'), findsOneWidget);
      repo.gate.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.textContaining('失败 1 项'), findsOneWidget);
      expect(repo.dirty, false);
      expect(find.textContaining('同步失败'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class ManagedCacheRepository extends CacheRepository {
  int measures = 0;
  int clears = 0;
  @override
  Future<FileCacheUsage> fileCacheUsage(StoredSession session) async {
    measures++;
    return const FileCacheUsage(files: 1, bytes: 3);
  }

  @override
  Future<void> clearFileCache(StoredSession session) async {
    clears++;
  }
}
