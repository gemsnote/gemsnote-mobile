import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/services/attachment_sharer.dart';
import 'package:gemsnote/services/note_sharer.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('OUTBOUND_SHARE_RUN');
  testWidgets('Android outbound text and files reach a real local receiver', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(run), isTrue);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Outbound share verification')),
      ),
    );
    const origin = Rect.fromLTWH(10, 100, 100, 40);
    for (final kind in ['md', 'html']) {
      debugPrint('OUTBOUND_SHARE_STAGE:$kind');
      await NoteSharer().share(
        Note.fromJson({
          'Title': 'share-$run-$kind',
          'Content': kind == 'md'
              ? '# 原文 📝\n\n**不截断**'
              : '<p>原文 &amp; emoji 📝</p>',
          'IsMarkdown': kind == 'md',
          'UserId': 'private-account-must-not-be-shared',
          'Tags': ['private-tag-must-not-be-shared'],
        }),
        origin,
      );
      await tester.pumpAndSettle();
    }
    debugPrint('OUTBOUND_SHARE_STAGE:binary');
    await AttachmentSharer().share(
      'share-$run-附件?.BIN',
      Uint8List.fromList([0, 1, 127, 128, 255]),
      origin,
    );
    await tester.pumpAndSettle();
    debugPrint('OUTBOUND_SHARE_STAGE:empty');
    await AttachmentSharer().share(
      'share-$run-empty.bin',
      Uint8List(0),
      origin,
    );
    await tester.pumpAndSettle();
    debugPrint('OUTBOUND_SHARE_STAGE:cancel');
    await NoteSharer().share(
      Note.fromJson({
        'Title': 'cancel-$run',
        'Content': 'must not be delivered',
      }),
      origin,
    );
    debugPrint('OUTBOUND_SHARE_STAGE:complete');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
