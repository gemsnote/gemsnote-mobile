import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/workspace_page.dart';

import 'foreground_sync_test.dart' show ForegroundRepository;

class FullRepository extends ForegroundRepository {
  final finish = Completer<void>();
  SyncProgressCallback? progress;
  int fullCalls = 0;
  @override
  Future<void> synchronizeFull(
    StoredSession session, {
    SyncProgressCallback? onProgress,
  }) async {
    fullCalls++;
    progress = onProgress;
    onProgress?.call(const SyncProgress(SyncStage.uploading, 0));
    await finish.future;
    dirty = false;
  }
}

void main() {
  testWidgets(
    'full sync closes account menu, displays progress, and closes on completion',
    (tester) async {
      final repo = FullRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(
              account: Account(
                userId: 'u',
                server: Uri.parse('https://example.test/'),
                username: 'u',
                email: '',
                logo: '',
              ),
              token: 'test',
            ),
            onSignedOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完全同步（合并）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.fullCalls, 1);
      expect(repo.calls, 0);
      expect(find.text('完全同步（合并）'), findsNothing);
      expect(find.text('正在上传本地修改，已上传 0 篇'), findsOneWidget);
      repo.progress?.call(const SyncProgress(SyncStage.notes, 20));
      await tester.pump();
      expect(find.text('正在下载笔记正文，已接收 20 篇'), findsOneWidget);
      repo.finish.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('同步完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
