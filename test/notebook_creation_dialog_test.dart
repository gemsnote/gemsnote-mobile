import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/notebook_creation_dialog.dart';
import 'package:gemsnote/ui/notebook_dialog.dart';

import 'foreground_sync_test.dart' show ForegroundRepository;

const local = Notebook(
  notebookId: 'local',
  parentNotebookId: '',
  title: 'New book',
  sequence: 0,
  usn: 0,
  numberNotes: 0,
  isDeleted: false,
  isDirty: true,
);
const remote = Notebook(
  notebookId: '507f1f77bcf86cd799439011',
  parentNotebookId: '',
  title: 'New book',
  sequence: 0,
  usn: 3,
  numberNotes: 0,
  isDeleted: false,
);

class CreationRepository extends ForegroundRepository {
  String state = 'uncertain';
  int creates = 0, lookups = 0, confirms = 0, retries = 0;
  Completer<void>? createGate;
  @override
  Future<Notebook> createOfflineNotebook(
    StoredSession session,
    String title,
    String parentId,
  ) async {
    creates++;
    expect(title, 'New book');
    expect(parentId, 'parent');
    await createGate?.future;
    return local;
  }

  @override
  Future<String?> notebookCreationState(
    StoredSession session,
    String id,
  ) async => state;
  @override
  Future<List<Notebook>> notebookCreationCandidates(
    StoredSession session,
    String id,
  ) async {
    lookups++;
    return [remote];
  }

  @override
  Future<void> confirmNotebookCreation(
    StoredSession session,
    String id,
    Notebook remote,
  ) async {
    confirms++;
    expect(id, local.notebookId);
    state = 'complete';
  }

  @override
  Future<void> retryNotebookCreation(StoredSession session, String id) async {
    retries++;
    state = 'pending';
  }
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
    token: 't',
  );
  Future<void> mount(WidgetTester tester, Widget dialog) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'offline creation prevents duplicate saves while persisting local child',
    (tester) async {
      final repo = CreationRepository()..createGate = Completer<void>();
      await mount(
        tester,
        NotebookDialog(
          repository: repo,
          session: session,
          parentNotebookId: 'parent',
        ),
      );
      expect(find.text('先保存到本机，下次同步时上传。'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'New book');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      expect(repo.creates, 1);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      repo.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(NotebookDialog), findsNothing);
      expect(repo.lookups, 0);
    },
  );

  testWidgets(
    'recovery opens offline and requires explicit association confirmation',
    (tester) async {
      final repo = CreationRepository();
      await mount(
        tester,
        NotebookCreationDialog(
          repository: repo,
          session: session,
          notebook: local,
        ),
      );
      expect(repo.lookups, 0);
      await tester.tap(find.text('查询服务端匹配项'));
      await tester.pumpAndSettle();
      expect(repo.lookups, 1);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.confirms, 0);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(repo.confirms, 1);
      expect(repo.creates, 0);
      expect(find.byType(NotebookCreationDialog), findsNothing);
    },
  );

  testWidgets('retry permission is explicit and never creates on its own', (
    tester,
  ) async {
    final repo = CreationRepository();
    await mount(
      tester,
      NotebookCreationDialog(
        repository: repo,
        session: session,
        notebook: local,
      ),
    );
    await tester.tap(find.text('核实后允许重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.retries, 0);
    await tester.tap(find.text('核实后允许重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(repo.retries, 1);
    expect(repo.creates, 0);
    expect(repo.lookups, 0);
  });
}
