import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/session/session_store.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/default_editor.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/home_widget.dart';
import 'package:gemsnote/services/shared_text_inbox.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/note_editor_page.dart';
import 'package:gemsnote/ui/note_reader_page.dart';
import 'package:gemsnote/ui/workspace_page.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('launcher opens, defers and saves through the offline workspace', (
    tester,
  ) async {
    expect(Platform.isAndroid, true);
    const run = String.fromEnvironment('WIDGET_TEST_RUN');
    expect(run, isNotEmpty);
    final directory = await (await getTemporaryDirectory()).createTemp(
      'widget-workspace-',
    );
    final path = '${directory.path}/notes.sqlite';
    var db = await AppDatabase.open(databasePath: path);
    final controller = HomeWidgetController();
    final account = Account(
      userId: 'widget-workspace-$run',
      server: Uri.parse('https://widget-workspace.invalid'),
      username: 'fixture',
      email: '',
      logo: '',
    );
    final session = StoredSession(account: account, token: 'unused-test-token');
    var networkRequests = 0;
    final client = MockClient((_) async {
      networkRequests++;
      throw StateError('Widget navigation must remain offline');
    });
    final api = Api2Client(httpClient: client);
    final repo = AuthRepository(
      api,
      db,
      const SecureSessionStore(),
      SyncCoordinator(api, db),
    );
    const sourceId = '507f1f77bcf86cd799439021';
    const bookId = '507f1f77bcf86cd799439022';
    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(ready(), true, reason: 'Workspace did not reach expected state');
      await tester.pumpAndSettle();
    }

    void stage(String name) {
      // ignore: avoid_print
      print('WIDGET_STAGE:$name');
    }

    try {
      await db.replaceSnapshot(
        account: account,
        notebooks: [
          Notebook.fromJson({
            'NotebookId': bookId,
            'Title': 'Widget test book',
          }),
        ],
        notes: [
          Note.fromJson({
            'NoteId': sourceId,
            'NotebookId': bookId,
            'UserId': account.userId,
            'Title': 'Widget workspace source',
            'Content': 'Offline source body',
            'IsMarkdown': true,
            'UpdatedTime': '2020-01-01T00:00:00Z',
          }),
        ],
        tags: [],
        lastSyncUsn: 1,
      );
      await db.setDefaultEditor(account.cacheKey, DefaultEditor.markdown);
      await db.setAutoSync(account.cacheKey, false);
      await db.setAutoCacheFiles(account.cacheKey, false);
      Future<List<Note>> load() => db.notes(account.cacheKey);
      await controller.activate(session, load);
      expect(controller.ready, true);
      expect(controller.error, isNull);
      await controller.setEnabled(true, load);
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: session,
            onSignedOut: () {},
            homeWidget: controller,
            // This test must not claim unrelated incoming shares.
            sharedTextInbox: SharedTextInbox(supported: false),
          ),
        ),
      );
      await until(() => find.text('Widget test book').evaluate().isNotEmpty);
      stage('workspace-open');
      await until(() => find.byType(NoteReaderPage).evaluate().isNotEmpty);
      expect(
        tester.widget<NoteReaderPage>(find.byType(NoteReaderPage)).note.noteId,
        sourceId,
      );
      expect(find.text('Offline source body'), findsWidgets);
      expect(controller.pending, isNull);

      // A new launcher action must not replace an already-open reader.
      stage('workspace-defer');
      await until(() => controller.pending?.action == 'create');
      expect(find.byType(NoteReaderPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pageBack();
      await until(() => find.text('选择新笔记的笔记本').evaluate().isNotEmpty);
      expect(controller.pending, isNull);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Widget test book'),
        ),
      );
      await until(() => find.byType(NoteEditorPage).evaluate().isNotEmpty);
      final createdId = tester
          .widget<NoteEditorPage>(find.byType(NoteEditorPage))
          .note
          .noteId;
      expect(
        tester
            .widget<NoteEditorPage>(find.byType(NoteEditorPage))
            .note
            .isMarkdown,
        true,
      );
      final fields = find.descendant(
        of: find.byType(NoteEditorPage),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.first, 'Widget created locally');
      await tester.enterText(fields.last, 'New offline body from widget');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存到本地'));
      await until(() => find.byType(NoteEditorPage).evaluate().isEmpty);
      final saved = await db.searchableNote(account.cacheKey, createdId);
      expect(saved!.title, 'Widget created locally');
      expect(saved.content, 'New offline body from widget');
      expect(saved.isMarkdown, true);
      expect(await db.notes(account.cacheKey), hasLength(2));
      // Workspace's refresh after editor completion publishes the saved title.
      stage('workspace-saved');
      await until(() => find.byType(NoteReaderPage).evaluate().isNotEmpty);
      expect(
        tester.widget<NoteReaderPage>(find.byType(NoteReaderPage)).note.noteId,
        createdId,
      );
      expect(find.text('New offline body from widget'), findsWidgets);
      expect(controller.pending, isNull);
      expect(networkRequests, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.raw.close();
      db = await AppDatabase.open(databasePath: path);
      final reopened = await db.searchableNote(account.cacheKey, createdId);
      expect(reopened!.title, saved.title);
      expect(reopened.content, saved.content);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await controller.setEnabled(false, () async => []);
      await controller.activate(null, null);
      controller.dispose();
      client.close();
      if (db.raw.isOpen) await db.raw.close();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
