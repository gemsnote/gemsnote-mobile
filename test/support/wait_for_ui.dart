import 'package:flutter_test/flutter_test.dart';

// SQLite FFI completes on real event-loop time, independently of fake timers.
Future<void> waitForUi(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      if (ready()) return;
    }
    throw TestFailure('Timed out waiting for $description');
  });
  await tester.pumpAndSettle();
}
