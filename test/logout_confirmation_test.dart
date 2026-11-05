import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/logout_confirmation_dialog.dart';

void main() {
  for (final choice in ['取消', '不同步退出']) {
    testWidgets('logout confirmation: $choice', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await confirmUnsyncedLogout(context);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('仍有未同步的修改'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextButton),
        ),
        findsNWidgets(2),
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(result, choice == '不同步退出');
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
