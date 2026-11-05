import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_creation_review.dart';
import 'package:gemsnote/ui/note_creation_dialog.dart';

void main() {
  const local = Note(
    noteId: 'n',
    notebookId: 'b',
    userId: 'u',
    title: 'local title',
    content: 'local body',
    tags: [],
    usn: 0,
    isMarkdown: true,
    isStarred: false,
    isTrash: false,
    isDeleted: false,
    createdTime: '',
    updatedTime: '',
  );
  final review = NoteCreationReview(
    accountId: 'a',
    local: local,
    remote: local.copyWith(
      title: 'remote title',
      content: 'remote body',
      usn: 8,
    ),
  );
  testWidgets(
    'explicit fetch and confirmation; cancellation preserves review and makes no mutation',
    (tester) async {
      int reads = 0, writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => NoteCreationDialog(
                    load: () async {
                      reads++;
                      return review;
                    },
                    recover: (_) async {
                      writes++;
                    },
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(reads, 0);
      expect(find.text('保留本地并恢复同步'), findsNothing);
      await tester.tap(find.text('读取远端并核对'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.text('local title'), findsOneWidget);
      expect(find.text('remote title'), findsOneWidget);
      await tester.ensureVisible(find.text('保留本地并恢复同步'));
      await tester.tap(find.text('保留本地并恢复同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.text('保留本地并恢复同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.byType(NoteCreationDialog), findsNothing);
    },
  );
  testWidgets('stale confirmation clears review and requires refetch', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCreationDialog(
            load: () async => review,
            recover: (_) async => throw StateError('noteCreationRemoteChanged'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('读取远端并核对'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保留本地并恢复同步'));
    await tester.tap(find.text('保留本地并恢复同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保留本地并恢复同步'), findsNothing);
    expect(find.text('远端笔记已变化，请重新读取并核对。'), findsOneWidget);
  });
}
