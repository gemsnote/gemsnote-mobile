import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/default_editor.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/home_widget.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/note_editor_page.dart';
import 'package:gemsnote/ui/note_reader_page.dart';
import 'package:gemsnote/ui/workspace_page.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

class WidgetActions extends HomeWidgetController {
  WidgetActions() : super(supported: false);
  final acknowledged = <String>[];
  void deliver(HomeWidgetAction value) {
    pending = value;
    notifyListeners();
  }

  @override
  Future<void> acknowledge(HomeWidgetAction action) async {
    acknowledged.add(action.id);
    if (pending?.id == action.id) pending = null;
  }
}

void main() {
  for (final mode in ['open', 'create', 'wrongAccount', 'missing', 'defer']) {
    testWidgets('widget navigation remains offline and scoped: $mode', (
      tester,
    ) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      late AppDatabase db;
      final account = Account(
        userId: 'u',
        server: Uri.parse('https://example.test/'),
        username: 'user',
        email: '',
        logo: '',
      );
      final note = Note.fromJson({
        'NoteId': '000000000000000000000001',
        'NotebookId': 'b',
        'UserId': 'u',
        'Title': 'Saved note',
        'Content': 'Saved body',
        'IsMarkdown': true,
      });
      await tester.runAsync(() async {
        db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
        await db.replaceSnapshot(
          account: account,
          notebooks: [
            Notebook.fromJson({'NotebookId': 'b', 'Title': 'Book'}),
          ],
          notes: [note],
          tags: [],
          lastSyncUsn: 3,
        );
        await db.setDefaultEditor(account.cacheKey, DefaultEditor.markdown);
      });
      addTearDown(db.raw.close);
      final api = Api2Client(
        httpClient: MockClient(
          (_) async => throw StateError('must stay offline'),
        ),
      );
      final repo = AuthRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
      );
      final bridge = WidgetActions();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(account: account, token: 't'),
            onSignedOut: () {},
            homeWidget: bridge,
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
        }
        await tester.pumpAndSettle();
      }

      await settle();
      if (mode == 'defer') {
        await tester.tap(find.text('Book'));
        await settle();
        await tester.tap(find.text('Saved note'));
        await settle();
        expect(find.byType(NoteReaderPage), findsOneWidget);
      }
      bridge.deliver(
        HomeWidgetAction(
          'request',
          mode == 'wrongAccount' ? 'other-account' : account.cacheKey,
          mode == 'create' || mode == 'defer' ? 'create' : 'open',
          mode == 'missing' ? '000000000000000000000002' : note.noteId,
        ),
      );
      await settle();
      if (mode == 'defer') {
        expect(bridge.acknowledged, isEmpty);
        expect(find.text('选择新笔记的笔记本'), findsNothing);
        await tester.pageBack();
        await settle();
      }
      expect(bridge.acknowledged, ['request']);
      if (mode == 'create' || mode == 'defer') {
        expect(find.text('选择新笔记的笔记本'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Book'),
          ),
        );
        await settle();
        expect(find.byType(NoteEditorPage), findsOneWidget);
        expect(
          tester
              .widget<NoteEditorPage>(find.byType(NoteEditorPage))
              .note
              .isMarkdown,
          isTrue,
        );
        await tester.runAsync(() async {
          expect(await db.notes(account.cacheKey), hasLength(2));
        });
        await tester.tap(find.byTooltip('保存到本地'));
        await settle();
      } else if (mode == 'open') {
        expect(find.byType(NoteReaderPage), findsOneWidget);
        expect(find.text('Saved body'), findsWidgets);
      } else {
        expect(find.byType(NoteReaderPage), findsNothing);
        expect(find.textContaining('打开小组件失败'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
