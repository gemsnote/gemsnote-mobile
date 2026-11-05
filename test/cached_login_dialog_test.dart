import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/cached_login_dialog.dart';

void main() {
  for (final reset in [false, true]) {
    testWidgets('cached login requires choice: reset=$reset', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await chooseCachedLoginReset(context);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('发现此账号的本地缓存'), findsOneWidget);
      expect(find.textContaining('未上传修改将被丢弃'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text(reset ? '重新同步' : '不同步'));
      await tester.pumpAndSettle();
      expect(result, reset);
    });
  }
}
