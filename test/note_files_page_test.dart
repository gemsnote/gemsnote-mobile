import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/note_files_page.dart';
import 'package:gemsnote/services/image_exporter.dart';
import 'package:gemsnote/services/attachment_exporter.dart';

class FilesRepository implements AuthRepository {
  bool deny = false;
  bool badImage = false;
  int downloads = 0;
  int attachmentDownloads = 0;
  final attachmentModes = <bool>[];
  @override
  Future<Uint8List> noteAttachment(
    StoredSession session,
    String noteId,
    NoteFile file, {
    bool cachedOnly = false,
  }) async {
    attachmentModes.add(cachedOnly);
    attachmentDownloads++;
    if (deny) throw StateError('noPermission');
    return Uint8List.fromList([1, 2, 3]);
  }

  final listModes = <bool>[];
  final imageModes = <bool>[];
  @override
  Future<List<NoteFile>> noteFiles(
    StoredSession session,
    String noteId, {
    bool cachedOnly = false,
  }) async {
    listModes.add(cachedOnly);
    expect(noteId, 'note');
    if (deny) throw StateError('noPermission');
    return const [
      NoteFile(id: 'image', title: 'Photo', type: 'png', isAttachment: false),
      NoteFile(
        id: 'attach',
        title: 'Document',
        type: 'pdf',
        isAttachment: true,
      ),
    ];
  }

  @override
  Future<Uint8List> noteImage(
    StoredSession session,
    String noteId,
    NoteFile file, {
    bool cachedOnly = false,
  }) async {
    imageModes.add(cachedOnly);
    downloads++;
    if (deny) throw StateError('noPermission');
    return badImage
        ? Uint8List.fromList([0])
        : File('assets/images/gemsnote_s.png').readAsBytesSync();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('explicit offline toggle reaches cached list and image methods', (
    tester,
  ) async {
    final repo = FilesRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: NoteFilesPage(
          repository: repo,
          session: StoredSession(
            account: Account(
              userId: 'u',
              server: Uri.parse('https://example.test'),
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
    await tester.tap(find.text('离线缓存'));
    await tester.pumpAndSettle();
    expect(repo.listModes, [false, true]);
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    expect(repo.imageModes, [true]);
  });
  Future<void> mount(
    WidgetTester tester,
    FilesRepository repo, {
    ImageExporter? exporter,
    AttachmentExporter? attachmentExporter,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NoteFilesPage(
          repository: repo,
          session: StoredSession(
            account: Account(
              userId: 'user',
              server: Uri.parse('https://example.test'),
              username: 'user',
              email: '',
              logo: '',
            ),
            token: 'test',
          ),
          noteId: 'note',
          imageExporter: exporter,
          attachmentExporter: attachmentExporter,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final result in ['success', 'cancel', 'error', 'downloadError']) {
    testWidgets('attachment save $result using explicit offline mode', (
      tester,
    ) async {
      final repo = FilesRepository();
      var calls = 0;
      final pending = Completer<Uri?>();
      await mount(
        tester,
        repo,
        attachmentExporter: AttachmentExporter(
          save: ({required fileName, required bytes, required mimeType}) {
            calls++;
            expect(bytes, [1, 2, 3]);
            return pending.future;
          },
        ),
      );
      await tester.tap(find.text('离线缓存'));
      await tester.pumpAndSettle();
      final item = find.ancestor(
        of: find.text('Document'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(item).onTap, isNotNull);
      expect(repo.attachmentDownloads, 0);
      repo.deny = result == 'downloadError';
      await tester.tap(find.text('Document'));
      await tester.pump();
      if (result != 'downloadError') {
        expect(tester.widget<ListTile>(item).onTap, isNull);
        if (result == 'error') {
          pending.completeError(StateError('disk full'));
        } else {
          pending.complete(
            result == 'success' ? Uri.parse('content://saved/file') : null,
          );
        }
      }
      await tester.pumpAndSettle();
      expect(calls, result == 'downloadError' ? 0 : 1);
      expect(repo.attachmentDownloads, 1);
      expect(repo.attachmentModes, [true]);
      expect(
        find.text('附件已保存'),
        result == 'success' ? findsOneWidget : findsNothing,
      );
      expect(
        find.textContaining('保存附件失败'),
        ['error', 'downloadError'].contains(result)
            ? findsOneWidget
            : findsNothing,
      );
      expect(tester.widget<ListTile>(item).onTap, isNotNull);
    });
  }

  for (final result in ['success', 'cancel', 'error']) {
    testWidgets(
      'offline image save $result does not redownload and allows retry',
      (tester) async {
        final repo = FilesRepository();
        var calls = 0;
        var pending = Completer<Uri?>();
        await mount(
          tester,
          repo,
          exporter: ImageExporter(
            save: ({required fileName, required bytes, required mimeType}) {
              calls++;
              expect(fileName, 'Photo.png');
              expect(mimeType, 'image/png');
              return pending.future;
            },
          ),
        );
        await tester.tap(find.text('离线缓存'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Photo'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('保存图片'));
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) => widget is IconButton && widget.tooltip == '正在保存…',
                ),
              )
              .onPressed,
          isNull,
        );
        if (result == 'error') {
          pending.completeError(StateError('disk full'));
        } else {
          pending.complete(
            result == 'success' ? Uri.parse('content://saved/image') : null,
          );
        }
        await tester.pumpAndSettle();
        expect(
          find.text('图片已保存'),
          result == 'success' ? findsOneWidget : findsNothing,
        );
        expect(
          find.textContaining('保存图片失败'),
          result == 'error' ? findsOneWidget : findsNothing,
        );
        expect(repo.imageModes, [true]);
        expect(calls, 1);
        pending = Completer<Uri?>();
        await tester.tap(find.byTooltip('保存图片'));
        await tester.pump();
        pending.complete(null);
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(repo.downloads, 1);
      },
    );
  }

  testWidgets(
    'lists files without downloading; only image opens zoomable preview',
    (tester) async {
      final repo = FilesRepository();
      await mount(tester, repo);
      expect(repo.downloads, 0);
      final attachment = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Document'),
          matching: find.byType(ListTile),
        ),
      );
      expect(attachment.onTap, isNotNull);
      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      expect(repo.downloads, 1);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).policy, ResizeImagePolicy.fit);
    },
  );
  testWidgets(
    'revocation errors do not open image and failed refresh removes visible stale list',
    (tester) async {
      final repo = FilesRepository();
      await mount(tester, repo);
      repo.deny = true;
      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('读取图片失败'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.tap(find.byTooltip('刷新文件列表'));
      await tester.pumpAndSettle();
      expect(find.text('Photo'), findsNothing);
      expect(find.textContaining('读取文件列表失败'), findsOneWidget);
      repo.deny = false;
      await tester.tap(find.byTooltip('刷新文件列表'));
      await tester.pumpAndSettle();
      expect(find.text('Photo'), findsOneWidget);
    },
  );
  testWidgets('bad image bytes show decode error instead of blank page', (
    tester,
  ) async {
    final repo = FilesRepository()..badImage = true;
    await mount(tester, repo);
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法解码图片，请返回重试'), findsOneWidget);
  });
}
