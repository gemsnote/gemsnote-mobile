import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/ui/attachment_upload_dialog.dart';

void main() {
  testWidgets('upload failure blocks repeated mutation', (tester) async {
    var calls = 0;
    final pending = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentUploadDialog(
            file: AttachmentUpload(name: 'a.txt', bytes: Uint8List(1)),
            upload: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('上传'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
    );
    pending.completeError(StateError('network'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.textContaining('不要重复上传'), findsOneWidget);
    expect(calls, 1);
  });
}
