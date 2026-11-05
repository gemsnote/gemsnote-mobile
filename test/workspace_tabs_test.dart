import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/shared_note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/shared_notes_page.dart';
import 'package:gemsnote/ui/workspace_page.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

class _TabRepository extends AuthRepository {
  _TabRepository(super.api, super.database, super.sessions, super.sync);

  int sharedLoads = 0;

  @override
  Future<List<SharedNote>> sharedNotes(
    StoredSession session, {
    bool cachedOnly = false,
  }) async {
    sharedLoads++;
    return [
      SharedNote(
        note: Note.fromJson({'NoteId': 'shared', 'Title': 'Received note'}),
        version: 'test',
      ),
    ];
  }
}

void main() {
  testWidgets(
    'home tabs switch without pushing routes and retain personal selection',
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
          notebooks: [
            Notebook.fromJson({'NotebookId': 'book', 'Title': 'My book'}),
          ],
          tags: [],
          lastSyncUsn: 3,
          notes: [
            Note.fromJson({
              'NoteId': 'plain',
              'NotebookId': 'book',
              'Title': 'Plain note',
            }),
            Note.fromJson({
              'NoteId': 'star',
              'NotebookId': 'book',
              'Title': 'Favorite note',
              'IsStar': true,
            }),
          ],
        );
      });
      addTearDown(db.raw.close);
      final api = Api2Client(
        httpClient: MockClient((_) async => throw StateError('offline')),
      );
      final repo = _TabRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspacePage(
            repository: repo,
            session: StoredSession(account: account, token: 'test'),
            onSignedOut: () {},
          ),
        ),
      );
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tab(int index) async {
        await tester.tap(find.byType(NavigationDestination).at(index));
        await settle();
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          index,
        );
        expect(
          Navigator.of(tester.element(find.byType(WorkspacePage))).canPop(),
          false,
        );
      }

      await settle();
      expect(repo.sharedLoads, 0); // Shared is loaded only when first selected.
      expect(find.text('我共享的'), findsOneWidget);
      expect(find.text('共享笔记'), findsNothing);
      await tester.tap(find.text('所有笔记'));
      await settle();
      await tab(1);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.text('Favorite note'), findsOneWidget);
      expect(find.text('Plain note'), findsNothing);
      await tab(0);
      expect(find.text('所有笔记'), findsOneWidget);
      expect(find.text('Plain note'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle();
      await tester.tap(find.text('My book'));
      await settle();

      await tab(2);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('Received note'), findsOneWidget);
      final sharedState = tester.state(find.byType(SharedNotesPage));
      await tab(1);
      expect(find.text('Favorite note'), findsOneWidget);
      expect(find.text('Plain note'), findsNothing);
      await tab(0);
      expect(find.text('My book'), findsOneWidget);
      expect(find.text('Plain note'), findsOneWidget);
      await tab(2);
      expect(tester.state(find.byType(SharedNotesPage)), same(sharedState));
      expect(repo.sharedLoads, 1);
      await tab(0);
      await tab(1);
      await tester.tap(find.byTooltip('取消星标'));
      await settle();
      expect(find.text('Favorite note'), findsNothing);
      await tab(0);
      expect(find.text('Favorite note'), findsOneWidget);
      expect(find.text('Plain note'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
