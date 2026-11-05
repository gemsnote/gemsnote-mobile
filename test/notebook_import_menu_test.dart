import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/import_note_dialog.dart';
import 'package:gemsnote/services/note_importer.dart';
import 'package:gemsnote/ui/workspace_page.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  testWidgets('notebook menu imports into its notebook without selecting it', (
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
    await tester.runAsync(() async {
      db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      await db.replaceSnapshot(
        account: account,
        notebooks: [
          Notebook.fromJson({'NotebookId': 'b', 'Title': 'Book'}),
          Notebook.fromJson({'NotebookId': 'dest', 'Title': 'Destination'}),
        ],
        notes: [],
        tags: [],
        lastSyncUsn: 3,
      );
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
    await tester.pumpWidget(
      MaterialApp(
        home: WorkspacePage(
          repository: repo,
          session: StoredSession(account: account, token: 't'),
          onSignedOut: () {},
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pumpAndSettle();
    }

    await settle();
    final menu = find.descendant(
      of: find
          .ancestor(
            of: find.text('Destination'),
            matching: find.byType(ListTile),
          )
          .first,
      matching: find.byType(PopupMenuButton<String>),
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('导出笔记本（ZIP）'), findsOneWidget);
    await tester.tap(find.text('导入笔记原文'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<ImportNoteDialog>(
      find.byType(ImportNoteDialog),
    );
    expect(dialog.targetTitle, 'Destination');
    expect(find.text('导入到：Destination'), findsOneWidget);
    await tester.runAsync(() async {
      final note = await dialog.onImport(
        const ImportedNote('Imported', '# original', true),
      );
      expect(note.notebookId, 'dest');
      final notes = await db.dirtyNotes(account.cacheKey);
      expect(notes, hasLength(1));
      expect(notes.single.notebookId, 'dest');
      expect(notes.single.title, 'Imported');
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
