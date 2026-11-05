import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/notebook_conflict.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/notebook_conflict_dialog.dart';

const local = Notebook(
  notebookId: '507f1f77bcf86cd799439011',
  parentNotebookId: '',
  title: 'Local draft name',
  sequence: 1,
  usn: 5,
  numberNotes: 0,
  isDeleted: false,
  isDirty: true,
);
const remote = Notebook(
  notebookId: '507f1f77bcf86cd799439011',
  parentNotebookId: '',
  title: 'Remote name',
  sequence: 1,
  usn: 8,
  numberNotes: 0,
  isDeleted: false,
);
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

class ReviewRepository implements AuthRepository {
  int reads = 0, writes = 0;
  bool fail = false;
  bool? keep;
  Completer<void>? gate;
  @override
  Future<NotebookConflictSnapshot> reviewNotebookConflict(
    StoredSession session,
    String id,
  ) async {
    reads++;
    return NotebookConflictSnapshot(
      accountId: session.account.cacheKey,
      local: local,
      remote: remote,
      remoteBooks: [remote],
    );
  }

  @override
  Future<void> resolveNotebookConflict(
    StoredSession session,
    NotebookConflictSnapshot reviewed, {
    required bool keepLocal,
  }) async {
    writes++;
    keep = keepLocal;
    await gate?.future;
    if (fail) throw StateError('notebookConflictRemoteChanged');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> open(WidgetTester tester, ReviewRepository repo) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => NotebookConflictDialog(
                  repository: repo,
                  session: session,
                  notebook: local,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final keep in [true, false]) {
    testWidgets(
      'review starts offline, confirms choice and disables duplicate submission: $keep',
      (tester) async {
        final repo = ReviewRepository()..gate = Completer<void>();
        await open(tester, repo);
        expect(repo.reads, 0);
        expect(repo.writes, 0);
        expect(find.text('Local draft name'), findsOneWidget);
        await tester.tap(find.text('读取远端并核对'));
        await tester.pumpAndSettle();
        expect(repo.reads, 1);
        expect(find.text('Remote name'), findsOneWidget);
        final label = keep ? '保留本地修改' : '采用远端修改';
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(repo.writes, 0);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存'));
        await tester.pump();
        expect(repo.writes, 1);
        expect(repo.keep, keep);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '保留本地修改'))
              .onPressed,
          isNull,
        );
        repo.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(NotebookConflictDialog), findsNothing);
      },
    );
  }
  testWidgets(
    'changed remote invalidates reviewed choices and requires another read',
    (tester) async {
      final repo = ReviewRepository()..fail = true;
      await open(tester, repo);
      await tester.tap(find.text('读取远端并核对'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用远端修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('远端笔记本或父级再次变化'), findsOneWidget);
      expect(find.text('采用远端修改'), findsNothing);
      expect(find.text('Local draft name'), findsOneWidget);
      await tester.tap(find.text('读取远端并核对'));
      await tester.pumpAndSettle();
      expect(repo.reads, 2);
      expect(repo.writes, 1);
      expect(find.text('采用远端修改'), findsOneWidget);
    },
  );
}
