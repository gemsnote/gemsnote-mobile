import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/note_files_page.dart';

import 'note_files_page_test.dart' show FilesRepository;

class BatchRepository extends FilesRepository {
  Completer<void>? gate;
  bool failAttachment = true;
  @override
  Future<Uint8List> noteImage(
    StoredSession session,
    String noteId,
    NoteFile file, {
    bool cachedOnly = false,
  }) async {
    downloads++;
    expect(cachedOnly, isFalse);
    await gate?.future;
    return Uint8List(1);
  }

  @override
  Future<Uint8List> noteAttachment(
    StoredSession session,
    String noteId,
    NoteFile file, {
    bool cachedOnly = false,
  }) async {
    attachmentDownloads++;
    expect(cachedOnly, isFalse);
    await gate?.future;
    if (failAttachment) throw StateError('network failure');
    return Uint8List(0);
  }
}

void main() {
  Future<void> mount(WidgetTester tester, BatchRepository repo) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NoteFilesPage(
          repository: repo,
          session: StoredSession(
            account: Account(
              userId: 'u',
              server: Uri.parse('https://example.test/'),
              username: 'u',
              email: '',
              logo: '',
            ),
            token: 'test',
          ),
          noteId: 'note',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'batch caches both file types and retries only failed files without native save',
    (tester) async {
      final repo = BatchRepository();
      await mount(tester, repo);
      await tester.tap(find.text('缓存当前笔记文件'));
      await tester.pumpAndSettle();
      expect(repo.downloads, 1);
      expect(repo.attachmentDownloads, 1);
      expect(find.textContaining('已处理 2 个，失败 1 个'), findsOneWidget);
      repo.failAttachment = false;
      await tester.tap(find.text('重试失败文件'));
      await tester.pumpAndSettle();
      expect(repo.downloads, 1);
      expect(repo.attachmentDownloads, 2);
      expect(find.text('重试失败文件'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('缓存当前笔记文件'), findsNothing);
      expect(repo.listModes, [false, true]);
    },
  );

  testWidgets(
    'busy queue disables list changes; disposal is safe for late callbacks',
    (tester) async {
      final repo = BatchRepository()..gate = Completer<void>();
      await mount(tester, repo);
      await tester.tap(find.text('缓存当前笔记文件'));
      await tester.pump();
      expect(find.text('已处理 0/2，失败 0'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新文件列表',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      await tester.tap(find.text('停止下载'));
      await tester.pump();
      expect(find.text('正在停止，等待已开始的下载结束…'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      repo.gate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
