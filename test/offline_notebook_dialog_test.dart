import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/notebook_dialog.dart';
import 'package:gemsnote/ui/move_notebook_dialog.dart';
import 'package:gemsnote/ui/workspace_page.dart';

import 'foreground_sync_test.dart' show ForegroundRepository;
import 'data/notebook_move_test.dart' show book, source, target;

class OfflineBookRepository extends ForegroundRepository {
  int renames = 0;
  int moves = 0;
  bool pendingBook = false;
  bool failRename = false;
  Completer<void>? gate;
  @override
  Future<void> queueNotebookRename(
    StoredSession session,
    String id,
    String title,
  ) async {
    expect(id, source);
    expect(title, 'Offline name');
    renames++;
    await gate?.future;
    if (failRename) throw StateError('disk');
  }

  @override
  Future<void> queueNotebookMove(
    StoredSession session,
    String id,
    String parent,
  ) async {
    expect(id, source);
    expect(parent, target);
    moves++;
  }

  @override
  Future<List<Notebook>> notebooks(String accountId) async => [
    Notebook(
      notebookId: source,
      parentNotebookId: '',
      title: source,
      sequence: 4,
      usn: 5,
      numberNotes: 0,
      isDeleted: false,
      isDirty: pendingBook,
    ),
    book(target, ''),
  ];
}

void main() {
  final session = StoredSession(
    account: Account(
      userId: 'u',
      server: Uri.parse('https://notes.test/'),
      username: 'u',
      email: '',
      logo: '',
    ),
    token: 't',
  );
  testWidgets(
    'rename queues offline, prevents duplicates and offers retry on local failure',
    (tester) async {
      final repo = OfflineBookRepository()
        ..failRename = true
        ..gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotebookDialog(
              repository: repo,
              session: session,
              existing: book(source, ''),
            ),
          ),
        ),
      );
      expect(find.text('先保存到本机，下次同步时上传。'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Offline name');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(repo.renames, 1);
      repo.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      repo.failRename = false;
      repo.gate = null;
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repo.renames, 2);
    },
  );
  testWidgets('move queues selected target without invoking online move', (
    tester,
  ) async {
    final repo = OfflineBookRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveNotebookDialog(
            repository: repo,
            session: session,
            notebook: book(source, ''),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(target));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    expect(repo.moves, 1);
  });
  testWidgets('notebook-only edits show pending badge and sync marker', (
    tester,
  ) async {
    final repo = OfflineBookRepository()
      ..dirty = false
      ..pendingBook = true;
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
    expect(find.byTooltip('笔记本待同步'), findsOneWidget);
    expect(
      tester
          .widget<Badge>(
            find.descendant(
              of: find.byType(FloatingActionButton),
              matching: find.byType(Badge),
            ),
          )
          .isLabelVisible,
      true,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
