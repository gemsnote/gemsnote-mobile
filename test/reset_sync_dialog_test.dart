import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/reset_sync_dialog.dart';

void main() {
  for (final confirm in [false, true]) {
    testWidgets('reset requires explicit consent: $confirm', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await confirmResetSync(context);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未上传的修改将被丢弃'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text(confirm ? '确认重新同步' : '取消'));
      await tester.pumpAndSettle();
      expect(result, confirm);
    });
  }
}
