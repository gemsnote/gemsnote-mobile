import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_sort.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/workspace_page.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;
import 'support/wait_for_ui.dart';

void main() {
  testWidgets(
    'all notes includes orphan notes without notebooks and preserves sort on reopen',
    (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      late AppDatabase db;
      final account = Account(
        userId: 'u',
        server: Uri.parse('https://example.test/'),
        username: 'u',
        email: '',
        logo: '',
      );
      await tester.runAsync(() async {
        db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
        await db.replaceSnapshot(
          account: account,
          notebooks: [],
          tags: [],
          lastSyncUsn: 3,
          notes: [
            Note.fromJson({
              'NoteId': 'a',
              'NotebookId': 'missing',
              'Title': 'Alpha',
              'UpdatedTime': '2026-01-01',
              'CreatedTime': '2020-02-01',
            }),
            Note.fromJson({
              'NoteId': 'b',
              'NotebookId': '',
              'Title': 'Beta',
              'UpdatedTime': '2026-02-01',
              'CreatedTime': '2020-01-01',
            }),
            Note.fromJson({'NoteId': 'c', 'Title': 'Trash', 'IsTrash': true}),
          ],
        );
      });
      addTearDown(db.raw.close);
      final api = Api2Client(
        httpClient: MockClient(
          (_) async => throw StateError('must stay offline'),
        ),
      );
      final repo = SortRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
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
      Future<void> settleDatabase({bool notes = true}) async {
        await waitForUi(
          tester,
          () =>
              (notes
                  ? find.text('Alpha').evaluate().isNotEmpty &&
                        find.text('Beta').evaluate().isNotEmpty
                  : find.text('所有笔记').evaluate().isNotEmpty) &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          'notes database read',
        );
      }

      await settleDatabase(notes: false);
      await tester.tap(find.text('所有笔记'));
      await settleDatabase();
      expect(find.text('Trash'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Beta')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
      );
      for (final sort in [
        NoteSort.createdDescending,
        NoteSort.createdAscending,
      ]) {
        await tester.tap(find.byTooltip('笔记排序'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text(sort.label),
            matching: find.byType(CheckedPopupMenuItem<NoteSort>),
          ),
        );
        await settleDatabase();
        final descending = sort == NoteSort.createdDescending;
        expect(
          tester.getTopLeft(find.text(descending ? 'Alpha' : 'Beta')).dy,
          lessThan(
            tester.getTopLeft(find.text(descending ? 'Beta' : 'Alpha')).dy,
          ),
        );
        await tester.runAsync(() async {
          expect(await db.noteSort(account.cacheKey), sort);
        });
      }
      await tester.tap(find.byTooltip('笔记排序'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('标题：升序'),
          matching: find.byType(CheckedPopupMenuItem<NoteSort>),
        ),
      );
      await settleDatabase();
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy),
      );
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所有笔记'));
      await settleDatabase();
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy),
      );
      repo.failSave = true;
      await tester.tap(find.byTooltip('笔记排序'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('标题：降序'),
          matching: find.byType(CheckedPopupMenuItem<NoteSort>),
        ),
      );
      await settleDatabase();
      expect(find.text('保存排序设置失败，仍使用原排序'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy),
      );
      repo.failSave = false;
      await tester.tap(find.text('重试排序设置'));
      await settleDatabase();
      expect(
        tester.getTopLeft(find.text('Beta')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
      );
      // Recreate the entire workspace, not just its list route.
      await tester.pumpWidget(const SizedBox());
      repo.failLoad = true;
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(account: account, token: 'test-token'),
            onSignedOut: () {},
          ),
        ),
      );
      await settleDatabase(notes: false);
      await tester.tap(find.text('所有笔记'));
      await settleDatabase();
      expect(find.text('读取排序设置失败，暂按修改时间排序'), findsOneWidget);
      repo.failLoad = false;
      await tester.tap(find.text('重试排序设置'));
      await settleDatabase();
      expect(find.text('重试排序设置'), findsNothing);
      await tester.tap(find.byTooltip('笔记排序'));
      await tester.pumpAndSettle();
      final selected = tester.widget<CheckedPopupMenuItem<NoteSort>>(
        find.byWidgetPredicate(
          (w) =>
              w is CheckedPopupMenuItem<NoteSort> &&
              w.value == NoteSort.titleDescending,
        ),
      );
      expect(selected.checked, true);
    },
  );
}

class SortRepository extends AuthRepository {
  SortRepository(super.api, super.database, super.sessions, super.sync);
  bool failLoad = false;
  bool failSave = false;
  @override
  Future<NoteSort> noteSort(StoredSession session) {
    if (failLoad) throw StateError('read failure');
    return super.noteSort(session);
  }

  @override
  Future<void> setNoteSort(StoredSession session, NoteSort sort) {
    if (failSave) throw StateError('write failure');
    return super.setNoteSort(session, sort);
  }
}
