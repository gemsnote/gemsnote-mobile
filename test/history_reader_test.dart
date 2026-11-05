import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note_history.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/note_history_page.dart';
import 'package:gemsnote/ui/note_reader_page.dart';
import 'package:gemsnote/ui/safe_html_note_body.dart';
import 'package:gemsnote/ui/cached_markdown_image.dart';
import 'package:webview_flutter/webview_flutter.dart';

class HistoryPreviewRepository implements AuthRepository {
  final modes = <bool>[];
  @override
  Future<List<NoteHistory>> histories(
    StoredSession session,
    String noteId, {
    bool cachedOnly = false,
  }) async => [
    const NoteHistory(
      id: 'stable-id',
      updatedTime: '2026-09-30',
      updatedUserId: 'user',
    ),
  ];
  @override
  Future<String> historyContent(
    StoredSession session,
    String noteId,
    String historyId, {
    bool cachedOnly = false,
  }) async {
    expect(historyId, 'stable-id');
    modes.add(cachedOnly);
    return '<p>Historical HTML</p><img src="https://example.test/private">';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ImageHistoryRepository extends HistoryPreviewRepository {
  var downloads = 0;
  var reads = 0;
  @override
  Future<String> historyContent(
    StoredSession session,
    String noteId,
    String historyId, {
    bool cachedOnly = false,
  }) async => '<img src="/api/file/getImage?fileId=0123456789abcdef01234567">';
  @override
  Future<Uint8List?> cachedHistoryImage(
    StoredSession session,
    String noteId,
    String historyId,
    String content,
    bool isMarkdown,
    Uri uri,
  ) async {
    reads++;
    expect(historyId, 'stable-id');
    return null;
  }

  @override
  Future<Uint8List> downloadHistoryImage(
    StoredSession session,
    String noteId,
    String historyId,
    String content,
    bool isMarkdown,
    Uri uri,
  ) async {
    downloads++;
    expect(historyId, 'stable-id');
    return Uint8List.fromList([1]);
  }
}

void main() {
  for (final cached in [false, true]) {
    testWidgets('rich-text history uses native preview: cached=$cached', (
      tester,
    ) async {
      final repo = HistoryPreviewRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: NoteHistoryPage(
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
            note: Note.fromJson({
              'NoteId': 'n',
              'Title': 'Title',
              'IsMarkdown': false,
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (cached) {
        await tester.tap(find.text('离线缓存'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('2026-09-30'));
      await tester.pumpAndSettle();
      expect(repo.modes, [cached]);
      expect(find.byType(SafeHtmlNoteBody), findsOneWidget);
      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.byTooltip('编辑'), findsNothing);
      await tester.tap(find.byTooltip('查看原文'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '<p>Historical HTML</p><img src="https://example.test/private">',
        ),
        findsOneWidget,
      );
    });
  }
  for (final offline in [false, true]) {
    testWidgets(
      'historical images require explicit download and honor offline mode: $offline',
      (tester) async {
        final repo = ImageHistoryRepository();
        await tester.pumpWidget(
          MaterialApp(
            home: NoteHistoryPage(
              repository: repo,
              session: StoredSession(
                account: Account(
                  userId: 'u',
                  server: Uri.parse('https://example.test/'),
                  username: '',
                  email: '',
                  logo: '',
                ),
                token: 't',
              ),
              note: Note.fromJson({'NoteId': 'n', 'IsMarkdown': false}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (offline) {
          await tester.tap(find.text('离线缓存'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('2026-09-30'));
        await tester.pumpAndSettle();
        expect(repo.reads, 1);
        expect(repo.downloads, 0);
        final image = tester.widget<CachedMarkdownImage>(
          find.byType(CachedMarkdownImage),
        );
        expect(image.download == null, offline);
        if (!offline) {
          await tester.tap(find.text('下载图片'));
          await tester.pumpAndSettle();
          expect(repo.downloads, 1);
        } else {
          expect(find.text('下载图片'), findsNothing);
        }
      },
    );
  }
  testWidgets('history preview has no editing or mutation actions', (
    tester,
  ) async {
    final note = Note.fromJson({
      'NoteId': 'n',
      'Title': 'History',
      'Content': 'Historical body',
      'IsMarkdown': true,
    });
    await tester.pumpWidget(
      MaterialApp(home: NoteReaderPage(note: note, readOnly: true)),
    );
    expect(find.text('Historical body'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });
}
