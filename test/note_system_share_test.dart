import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/services/note_sharer.dart';
import 'package:gemsnote/ui/note_reader_page.dart';

void main() {
  Note note({
    String title = '珠玑',
    String content = '# Hello\n<script>raw()</script>',
  }) => Note.fromJson({
    'NoteId': 'n',
    'Title': title,
    'Content': content,
    'IsMarkdown': true,
  });
  const origin = Rect.fromLTWH(10, 20, 40, 40);
  for (final status in ShareResultStatus.values) {
    test(
      'shares exact source as text and accepts native result $status',
      () async {
        await NoteSharer(
          share: (params) async {
            expect(params.text, '珠玑\n\n# Hello\n<script>raw()</script>');
            expect(params.subject, '珠玑');
            expect(params.files, isNull);
            expect(params.uri, isNull);
            expect(params.sharePositionOrigin, origin);
            return ShareResult('', status);
          },
        ).share(note(), origin);
      },
    );
  }
  test('empty note has useful title; oversize and invalid anchor never open native sheet', () async {
    var calls = 0;
    final sharer = NoteSharer(
      share: (params) async {
        calls++;
        expect(params.text, '未命名笔记\n\n');
        return ShareResult.unavailable;
      },
    );
    await sharer.share(note(title: '', content: ''), origin);
    await expectLater(
      sharer.share(note(content: List.filled(90000, '珠').join()), origin),
      throwsStateError,
    );
    await expectLater(sharer.share(note(), Rect.zero), throwsStateError);
    expect(calls, 1);
  });
  for (final fail in [false, true]) {
    testWidgets('reader share disables duplicates and handles error=$fail', (
      tester,
    ) async {
      var calls = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: note(),
            onSystemShare: (rect) {
              calls++;
              expect(rect.width, greaterThan(0));
              expect(rect.height, greaterThan(0));
              return pending.future;
            },
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('系统分享原文'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      final item = find.ancestor(
        of: find.text('正在分享…'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isFalse);
      Navigator.of(tester.element(find.text('正在分享…'))).pop();
      await tester.pumpAndSettle();
      if (fail) {
        pending.completeError(StateError('native unavailable'));
      } else {
        pending.complete();
      }
      await tester.pumpAndSettle();
      expect(find.byType(NoteReaderPage), findsOneWidget);
      expect(
        find.textContaining('系统分享失败'),
        fail ? findsOneWidget : findsNothing,
      );
      expect(find.text('分享成功'), findsNothing);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('系统分享原文'), findsOneWidget);
    });
  }
  testWidgets('readonly notes never expose system sharing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NoteReaderPage(
          note: note(),
          readOnly: true,
          onSystemShare: (_) async => fail('readonly share'),
        ),
      ),
    );
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });
}
