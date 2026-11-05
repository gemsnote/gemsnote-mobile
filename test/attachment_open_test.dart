import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/attachment_opener.dart';
import 'package:gemsnote/ui/note_files_page.dart';

import 'note_files_page_test.dart' show FilesRepository;

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('attachment-open-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'exact bytes and safe extension are staged separately for every open',
    () async {
      final paths = <String>[];
      final opener = AttachmentOpener(
        temporaryDirectory: () async => temp,
        open: (file) async {
          paths.add(file);
          expect(await File(file).readAsBytes(), [1, 2, 3]);
          expect(path.isWithin(temp.path, file), true);
          expect(path.basename(file), endsWith('.pdf'));
          return OpenResult();
        },
      );
      for (var i = 0; i < 2; i++) {
        await opener.open(
          '../${'报告' * 120}.PDF',
          Uint8List.fromList([1, 2, 3]),
        );
      }
      expect(paths.toSet(), hasLength(2));
      for (final file in paths) {
        expect(await File(file).exists(), true);
      }
    },
  );
  test('oversized bytes and disposed page never invoke native open', () async {
    final opener = AttachmentOpener(
      temporaryDirectory: () async => temp,
      open: (_) async => throw TestFailure('must not open'),
    );
    await expectLater(
      opener.open('big', Uint8List(32 * 1024 * 1024 + 1)),
      throwsA(isA<AttachmentOpenException>()),
    );
    await opener.open('file', Uint8List(0), canOpen: () => false);
    expect(await temp.list().toList(), isEmpty);
  });
  test(
    'page leaving during staging cleans copy and suppresses native open',
    () async {
      var active = true;
      final opener = AttachmentOpener(
        temporaryDirectory: () async {
          active = false;
          return temp;
        },
        open: (_) async => throw TestFailure('must not open'),
      );
      await opener.open('empty.txt', Uint8List(0), canOpen: () => active);
      final root = Directory(path.join(temp.path, 'gemsnote-open-attachments'));
      expect(await root.list().toList(), isEmpty);
    },
  );
  for (final result in ResultType.values.where((v) => v != ResultType.done)) {
    test('native $result becomes an actionable error', () async {
      final opener = AttachmentOpener(
        temporaryDirectory: () async => temp,
        open: (_) async => OpenResult(type: result),
      );
      await expectLater(
        opener.open('empty.txt', Uint8List(0)),
        throwsA(isA<AttachmentOpenException>()),
      );
    });
  }
  test(
    'expired copies removed without touching unrelated files or directories',
    () async {
      final root = await Directory(
        path.join(temp.path, 'gemsnote-open-attachments'),
      ).create();
      final old = await Directory(path.join(root.path, 'open-old')).create();
      await File(path.join(old.path, 'old.txt')).writeAsString('old');
      final recent = await Directory(
        path.join(root.path, 'unrelated-directory'),
      ).create();
      final unrelated = await File(path.join(temp.path, 'keep.txt'))
          .writeAsString('keep');
      await AttachmentOpener(
        now: () => DateTime.now().add(const Duration(days: 2)),
        temporaryDirectory: () async => temp,
        open: (_) async => OpenResult(),
      ).open('new.txt', Uint8List(0));
      expect(await old.exists(), false);
      expect(await recent.exists(), true);
      expect(await unrelated.exists(), true);
    },
  );

  Future<void> mount(
    WidgetTester tester,
    FilesRepository repo,
    AttachmentOpener opener,
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
            token: 't',
          ),
          noteId: 'note',
          attachmentOpener: opener,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final offline in [false, true]) {
    testWidgets(
      'opening uses cachedOnly=$offline and blocks repeated actions',
      (tester) async {
        final repo = FilesRepository();
        final opener = FakeOpener();
        await mount(tester, repo, opener);
        if (offline) {
          await tester.tap(find.text('离线缓存'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('打开附件'));
        await tester.pump();
        expect(opener.calls, 1);
        expect(repo.attachmentModes, [offline]);
        await tester.tap(find.text('Document'));
        await tester.pump();
        expect(repo.attachmentDownloads, 1);
        opener.pending.complete();
        await tester.pumpAndSettle();
        expect(find.byTooltip('打开附件'), findsOneWidget);
      },
    );
  }
  testWidgets('download failure never opens; native refusal permits retry', (
    tester,
  ) async {
    final repo = FilesRepository();
    final opener = FakeOpener();
    await mount(tester, repo, opener);
    repo.deny = true;
    await tester.tap(find.byTooltip('打开附件'));
    await tester.pumpAndSettle();
    expect(opener.calls, 0);
    expect(find.textContaining('打开附件失败'), findsOneWidget);
    repo.deny = false;
    await tester.tap(find.byTooltip('打开附件'));
    await tester.pump();
    opener.pending.completeError(const AttachmentOpenException('没有可打开此附件的应用'));
    await tester.pumpAndSettle();
    expect(find.text('没有可打开此附件的应用'), findsOneWidget);
    opener.pending = Completer<void>();
    await tester.tap(find.byTooltip('打开附件'));
    await tester.pump();
    opener.pending.complete();
    await tester.pumpAndSettle();
    expect(opener.calls, 2);
    expect(find.text('没有可打开此附件的应用'), findsNothing);
  });
}

class FakeOpener extends AttachmentOpener {
  int calls = 0;
  var pending = Completer<void>();
  @override
  Future<void> open(String title, Uint8List bytes, {bool Function()? canOpen}) {
    expect(canOpen!(), true);
    expect(bytes, [1, 2, 3]);
    calls++;
    return pending.future;
  }
}
