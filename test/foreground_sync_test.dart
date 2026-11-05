import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/data/database/file_download_journal.dart';
import 'package:gemsnote/services/account_file_cache.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/workspace_page.dart';

class ForegroundRepository implements AuthRepository {
  bool autoSyncEnabled = false;
  @override
  Future<bool> autoSync(StoredSession session) async => autoSyncEnabled;
  @override
  Future<void> setAutoSync(StoredSession session, bool enabled) async {
    autoSyncEnabled = enabled;
  }
  @override
  AccountFileCache fileCacheQueue(StoredSession session) => AccountFileCache();
  @override
  Future<DownloadQueueStatus> downloadQueueStatus(
    StoredSession session,
  ) async => const DownloadQueueStatus();
  int calls = 0;
  bool fail = false;
  bool dirty = true;
  Completer<void>? pending;
  @override
  Future<List<Notebook>> notebooks(String accountId) async => [];
  @override
  Future<Uint8List?> cachedAvatar(StoredSession session) async => null;
  @override
  Future<void> refreshAccountPresentation(StoredSession session) async {}
  @override
  Future<Set<String>> pendingNoteIds(String accountId) async =>
      dirty ? {'note'} : {};
  @override
  Future<void> synchronize(
    StoredSession session, {
    SyncProgressCallback? onProgress,
  }) async {
    calls++;
    if (pending != null) await pending!.future;
    if (fail) throw StateError('offline');
    dirty = false;
  }

  @override
  Future<void> logout(
    StoredSession session, {
    bool discardSessionWithPendingChanges = false,
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final session = StoredSession(
    account: Account(
      userId: 'u',
      server: Uri.parse('https://example.test'),
      username: 'u',
      email: '',
      logo: '',
    ),
    token: 'test',
  );
  Future<void> mount(WidgetTester tester, ForegroundRepository repo) async {
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  Future<void> toggle(WidgetTester tester) async {
    await tester.tap(find.byTooltip('账号菜单'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is CheckedPopupMenuItem<String> &&
            widget.value == 'autoSync',
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'default offline; opt in syncs without modal or success toast; disable stops it',
    (tester) async {
      final repo = ForegroundRepository();
      await mount(tester, repo);
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 0);
      await toggle(tester);
      expect(repo.calls, 0);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repo.calls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('同步完成'), findsNothing);
      expect(find.byTooltip('立即同步（1 篇待上传）'), findsNothing);
      await toggle(tester);
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 1);
    },
  );

  testWidgets('saved auto-sync setting resumes after workspace recreation', (
    tester,
  ) async {
    final repo = ForegroundRepository();
    await mount(tester, repo);
    await toggle(tester);
    expect(repo.autoSyncEnabled, true);
    await tester.pumpWidget(const SizedBox());
    await mount(tester, repo);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(repo.calls, 1);
  });

  testWidgets(
    'background and covered routes pause scheduling; resume waits a full interval',
    (tester) async {
      final repo = ForegroundRepository();
      await mount(tester, repo);
      await toggle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 30));
      expect(repo.calls, 0);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Editor')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 0);
      nav.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repo.calls, 1);
    },
  );

  testWidgets('slow sync is not duplicated by timers or manual sync', (
    tester,
  ) async {
    final repo = ForegroundRepository()..pending = Completer<void>();
    await mount(tester, repo);
    await toggle(tester);
    await tester.pump(const Duration(minutes: 1));
    expect(repo.calls, 1);
    await tester.pump(const Duration(minutes: 3));
    expect(repo.calls, 1);
    // The account-menu action also uses the same workspace lock.
    await tester.tap(find.byTooltip('账号菜单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('立即同步'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.calls, 1);
    repo.pending!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'failure keeps dirty indicator and persistent error; next interval retries',
    (tester) async {
      final repo = ForegroundRepository()..fail = true;
      await mount(tester, repo);
      await toggle(tester);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('同步失败：'), findsOneWidget);
      expect(find.byTooltip('立即同步（1 篇待上传）'), findsOneWidget);
      repo.fail = false;
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repo.calls, 2);
      expect(find.textContaining('同步失败：'), findsNothing);
      expect(find.byTooltip('立即同步（1 篇待上传）'), findsNothing);
    },
  );

  testWidgets(
    'successful logout stops timer even before parent removes workspace',
    (tester) async {
      final repo = ForegroundRepository()..dirty = false;
      await mount(tester, repo);
      await toggle(tester);
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 0);
    },
  );

  testWidgets(
    'open menu defers sync and disposing workspace cancels the timer',
    (tester) async {
      final repo = ForegroundRepository();
      await mount(tester, repo);
      await toggle(tester);
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 0);
    },
  );
}
