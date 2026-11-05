import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/tags_page.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  testWidgets(
    'offline tags include unindexed notes and filtering finds tags outside top ten',
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
          lastSyncUsn: 0,
          notes: [
            for (var i = 0; i < 12; i++)
              Note.fromJson({
                'NoteId': 'n$i',
                'Tags': ['tag${i.toString().padLeft(2, '0')}'],
              }),
            Note.fromJson({
              'NoteId': 'extra',
              'Tags': ['tag11'],
            }),
            Note.fromJson({
              'NoteId': 'trash',
              'Tags': ['trash'],
              'IsTrash': true,
            }),
          ],
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
          home: TagsPage(repository: repo, accountId: account.cacheKey),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('显示笔记最多的 10 个标签，其他请过滤查找'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find
                  .descendant(
                    of: find
                        .descendant(
                          of: find.byType(ListView),
                          matching: find.byType(ListTile),
                        )
                        .first,
                    matching: find.byType(Text),
                  )
                  .first,
            )
            .data,
        'tag11',
      );
      await tester.enterText(find.byType(TextField), 'TAG10');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'tag10'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'trash');
      await tester.pump();
      expect(find.text('没有匹配的标签'), findsOneWidget);
      await tester.tap(find.byTooltip('清空过滤'));
      await tester.pump();
      expect(find.text('显示笔记最多的 10 个标签，其他请过滤查找'), findsOneWidget);
    },
  );
}
