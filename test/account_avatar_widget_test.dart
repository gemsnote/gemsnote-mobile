import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/account_avatar.dart';
import 'package:gemsnote/ui/workspace_page.dart';

class AvatarRepository implements AuthRepository {
  @override
  Future<String?> pendingMailTask(StoredSession session) async => null;
  @override
  Future<bool> autoSync(StoredSession session) async => false;
  Uint8List? avatar;
  var reads = 0;
  var refreshes = 0;
  Completer<void>? refresh;
  @override
  Future<void> refreshAccountPresentation(StoredSession session) async {
    refreshes++;
    await refresh?.future;
  }

  @override
  Future<Uint8List?> cachedAvatar(StoredSession session) async {
    reads++;
    return avatar;
  }

  @override
  Future<Account> cachedProfile(StoredSession session) async => session.account;
  @override
  Future<List<Notebook>> notebooks(String accountId) async => [];
  @override
  Future<Set<String>> pendingNoteIds(String accountId) async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'fresh login refresh is nonblocking and failure does not mark notes dirty',
    (tester) async {
      final repo = AvatarRepository()..refresh = Completer<void>();
      final account = Account(
        userId: 'u',
        server: Uri.parse('https://example.test/'),
        username: 'u',
        email: '',
        logo: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(account: account, token: 'test'),
            refreshAvatarOnStart: true,
            onSignedOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.refreshes, 1);
      expect(find.text('所有笔记'), findsOneWidget);
      expect(find.byTooltip('立即同步'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repo.refresh!.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.textContaining('头像刷新失败'), findsOneWidget);
      expect(find.byTooltip('立即同步'), findsOneWidget);
      expect(find.textContaining('同步失败：'), findsNothing);
    },
  );
  testWidgets('missing and corrupt cached images show fallback', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AccountAvatar()));
    expect(find.byIcon(Icons.account_circle), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(home: AccountAvatar(bytes: Uint8List.fromList([1, 2, 3]))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.account_circle), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets(
    'workspace refreshes avatar after account page without network calls',
    (tester) async {
      final repo = AvatarRepository();
      final account = Account(
        userId: 'u',
        server: Uri.parse('https://example.test/'),
        username: 'Zed',
        email: '',
        logo: '/avatar.png',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(account: account, token: 'test-token'),
            onSignedOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AccountAvatar>(find.byType(AccountAvatar)).bytes,
        null,
      );
      expect(find.text('Z'), findsNothing);
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('账号'));
      await tester.pumpAndSettle();
      repo.avatar = File('assets/images/gemsnote_s.png').readAsBytesSync();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.widget<AccountAvatar>(find.byType(AccountAvatar)).bytes,
        repo.avatar,
      );
      expect(repo.reads, 3); // Workspace, account page, then workspace refresh.
      expect(repo.refreshes, 0);
    },
  );
}
