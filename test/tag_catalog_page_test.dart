import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/create_tag_dialog.dart';
import 'package:gemsnote/ui/note_tags_dialog.dart';
import 'package:gemsnote/ui/tags_page.dart';

class CatalogRepository implements AuthRepository {
  final catalog = {'used': 3, 'unused': 0};
  final created = <String>[];
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<Map<String, int>> tagCounts(String accountId) async => {'used': 3};
  @override
  Future<Map<String, int>> availableTags(String accountId) async =>
      Map.of(catalog);
  @override
  Future<void> createTag(StoredSession session, String value) async {
    created.add(value);
    if (fail) throw StateError('offline');
    await pending?.future;
    catalog.putIfAbsent(value, () => 0);
  }

  @override
  Future<void> deleteTag(StoredSession session, String value) async {
    if (fail) throw StateError('offline');
    catalog.remove(value);
  }

  @override
  Future<void> renameTag(
    StoredSession session,
    String oldName,
    String newName,
  ) async {
    if (fail) throw StateError('offline');
    catalog[newName] = catalog.remove(oldName)!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  testWidgets('tag menu rename and confirmed delete refresh the catalog', (
    tester,
  ) async {
    final repo = CatalogRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: TagsPage(
          repository: repo,
          accountId: session.account.cacheKey,
          session: session,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示未使用标签'));
    await tester.pumpAndSettle();
    Future<void> menu(String tag) async {
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, tag),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
    }

    await menu('unused');
    await tester.tap(find.text('重命名标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'renamed');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'renamed'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'unused'), findsNothing);
    await menu('renamed');
    await tester.tap(find.text('删除标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(repo.catalog, contains('renamed'));
    await menu('renamed');
    await tester.tap(find.text('删除标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除标签'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'renamed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unused catalog is optional, searchable and refreshed after creation',
    (tester) async {
      final repo = CatalogRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: TagsPage(
            repository: repo,
            accountId: session.account.cacheKey,
            session: session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('unused'), findsNothing);
      await tester.tap(find.text('显示未使用标签'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'unused'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'UNUSED');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'used'), findsNothing);
      expect(find.widgetWithText(ListTile, 'unused'), findsOneWidget);
      await tester.tap(find.byTooltip('创建标签'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(CreateTagDialog),
          matching: find.byType(TextField),
        ),
        ' new ',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(repo.created, ['new']);
      expect(find.byType(CreateTagDialog), findsNothing);
      expect(find.widgetWithText(ListTile, 'new'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'unused'), findsOneWidget);
    },
  );

  testWidgets(
    'failure retains input, retry blocks navigation and duplicate taps',
    (tester) async {
      final repo = CatalogRepository()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TagsPage(
            repository: repo,
            accountId: session.account.cacheKey,
            session: session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('创建标签'));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(CreateTagDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'name');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未能确认创建成功'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, 'name');
      repo.fail = false;
      repo.pending = Completer<void>();
      await tester.tap(find.text('创建'));
      await tester.pump();
      await tester.tap(find.text('创建'));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(CreateTagDialog), findsOneWidget);
      expect(repo.created, ['name', 'name']);
      repo.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CreateTagDialog), findsNothing);
      expect(find.widgetWithText(ListTile, 'name'), findsOneWidget);
    },
  );

  testWidgets('note tag suggestions can select zero-use catalog entries', (
    tester,
  ) async {
    List<String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteTagsDialog(
            tags: const [],
            loadSuggestions: () async => {'unused': 0},
            onSave: (tags) async {
              saved = tags;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'unused'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, ['unused']);
  });
}
