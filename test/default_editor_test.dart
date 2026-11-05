import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/default_editor.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/default_editor_dialog.dart';
import 'package:gemsnote/ui/note_editor_page.dart';
import 'package:gemsnote/ui/workspace_page.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  testWidgets(
    'workspace saves preference and uses it for new notes, with explicit alternate',
    (tester) async {
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
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('默认编辑器'));
      await settle();
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await settle();
      expect(find.byType(DefaultEditorDialog), findsNothing);
      await tester.tap(find.text('Book'));
      await settle();
      await tester.tap(find.byType(FloatingActionButton));
      await settle();
      expect(find.text('默认：Markdown'), findsOneWidget);
      await tester.tap(find.text('新建笔记'));
      await settle();
      expect(
        tester
            .widget<NoteEditorPage>(find.byType(NoteEditorPage))
            .note
            .isMarkdown,
        true,
      );
      await tester.tap(find.byTooltip('保存到本地'));
      await settle();
      await tester.tap(find.byType(FloatingActionButton));
      await settle();
      await tester.tap(find.text('新建富文本'));
      await settle();
      expect(
        tester
            .widget<NoteEditorPage>(find.byType(NoteEditorPage))
            .note
            .isMarkdown,
        false,
      );
      await tester.runAsync(() async {
        expect(
          await db.defaultEditor(account.cacheKey),
          DefaultEditor.markdown,
        );
        expect((await db.dirtyNotes(account.cacheKey)).length, 2);
      });
    },
  );

  testWidgets('load and save failures stay visible, cancellation never saves', (
    tester,
  ) async {
    var loads = 0;
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DefaultEditorDialog(
                  load: () async {
                    loads++;
                    if (loads == 1) throw StateError('read failed');
                    return DefaultEditor.html;
                  },
                  save: (_) async {
                    saves++;
                    throw StateError('disk full');
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
    expect(find.textContaining('读取设置失败'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('重试读取'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存设置失败'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.byType(DefaultEditorDialog), findsNothing);
  });
}
