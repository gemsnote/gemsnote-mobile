import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/attachment_sharer.dart';
import 'package:gemsnote/ui/note_files_page.dart';

import 'note_files_page_test.dart' show FilesRepository;

void main() {
  const origin = Rect.fromLTWH(0, 0, 100, 100);
  test(
    'shares exact bytes with a bounded safe filename and no credentials',
    () async {
      final sharer = AttachmentSharer(
        share: (params) async {
          expect(await params.files!.single.readAsBytes(), [1, 2, 3]);
          expect(params.files!.single.mimeType, 'application/pdf');
          expect(params.fileNameOverrides!.single, endsWith('.pdf'));
          expect(
            params.fileNameOverrides!.single.length,
            lessThanOrEqualTo(84),
          );
          expect(params.fileNameOverrides!.single, isNot(contains('/')));
          expect(params.text, isNull);
          expect(params.uri, isNull);
          expect(params.subject, isNull);
          expect(params.sharePositionOrigin, origin);
          return const ShareResult('', ShareResultStatus.success);
        },
      );
      await sharer.share(
        '../${'报告' * 120}.PDF',
        Uint8List.fromList([1, 2, 3]),
        origin,
      );
    },
  );
  for (final status in ShareResultStatus.values) {
    test('empty attachment and $status are accepted', () async {
      await AttachmentSharer(
        share: (params) async {
          expect(await params.files!.single.readAsBytes(), isEmpty);
          expect(params.fileNameOverrides, ['附件']);
          expect(params.files!.single.mimeType, 'application/octet-stream');
          return ShareResult('', status);
        },
      ).share(' .. ', Uint8List(0), origin);
    });
  }
  test(
    'oversized attachment and invalid anchor never invoke native share',
    () async {
      final sharer = AttachmentSharer(
        share: (_) async => throw TestFailure('native call'),
      );
      await expectLater(
        sharer.share('big', Uint8List(32 * 1024 * 1024 + 1), origin),
        throwsStateError,
      );
      await expectLater(
        sharer.share('file', Uint8List(0), Rect.zero),
        throwsStateError,
      );
    },
  );

  Future<void> mount(
    WidgetTester tester,
    FilesRepository repo,
    AttachmentSharer sharer,
  ) async {
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
          attachmentSharer: sharer,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final offline in [false, true]) {
    testWidgets(
      'share mode offline=$offline blocks duplicate actions and permits cancel',
      (tester) async {
        final repo = FilesRepository();
        final pending = Completer<ShareResult>();
        var calls = 0;
        await mount(
          tester,
          repo,
          AttachmentSharer(
            share: (params) {
              calls++;
              expect(params.sharePositionOrigin!.isEmpty, isFalse);
              return pending.future;
            },
          ),
        );
        if (offline) {
          await tester.tap(find.text('离线缓存'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('分享附件'));
        await tester.pump();
        await tester.tap(find.text('Document'));
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton && widget.tooltip == '刷新文件列表',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(calls, 1);
        expect(repo.attachmentModes, [offline]);
        pending.complete(const ShareResult('', ShareResultStatus.dismissed));
        await tester.pumpAndSettle();
        expect(find.textContaining('分享附件失败'), findsNothing);
        expect(find.textContaining('分享成功'), findsNothing);
        expect(find.byTooltip('分享附件'), findsOneWidget);
      },
    );
  }
  for (final downloadError in [false, true]) {
    testWidgets('share failure download=$downloadError permits retry', (
      tester,
    ) async {
      final repo = FilesRepository();
      var fail = true;
      var calls = 0;
      await mount(
        tester,
        repo,
        AttachmentSharer(
          share: (_) async {
            calls++;
            if (fail) throw StateError('native unavailable');
            return const ShareResult('', ShareResultStatus.success);
          },
        ),
      );
      repo.deny = downloadError;
      await tester.tap(find.byTooltip('分享附件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('分享附件失败'), findsOneWidget);
      expect(calls, downloadError ? 0 : 1);
      repo.deny = false;
      fail = false;
      await tester.tap(find.byTooltip('分享附件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('分享附件失败'), findsNothing);
      expect(calls, downloadError ? 1 : 2);
    });
  }
  testWidgets('leaving while downloading does not launch native share', (
    tester,
  ) async {
    final repo = PendingFilesRepository();
    var calls = 0;
    await mount(
      tester,
      repo,
      AttachmentSharer(
        share: (_) async {
          calls++;
          return const ShareResult('', ShareResultStatus.success);
        },
      ),
    );
    await tester.tap(find.byTooltip('分享附件'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    repo.pending.complete(Uint8List.fromList([1]));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}

class PendingFilesRepository extends FilesRepository {
  final pending = Completer<Uint8List>();
  @override
  Future<Uint8List> noteAttachment(
    StoredSession session,
    String noteId,
    dynamic file, {
    bool cachedOnly = false,
  }) => pending.future;
}
