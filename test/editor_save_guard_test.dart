import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/editor_save_guard.dart';

void main() {
  test('exit waits for snapshot acceptance and persistence', () async {
    final snapshot = Completer<String>();
    final save = Completer<bool>();
    final events = <String>[];
    final result = persistVisualEdit(
      read: () => snapshot.future,
      accept: (value) {
        events.add(value);
        return true;
      },
      flush: () {
        events.add('flush');
        return save.future;
      },
    );
    var done = false;
    unawaited(result.then((_) => done = true));
    expect(events, isEmpty);
    snapshot.complete('<p>final edit</p>');
    await Future<void>.delayed(Duration.zero);
    expect(events, ['<p>final edit</p>', 'flush']);
    expect(done, isFalse);
    save.complete(true);
    expect(await result, isTrue);
  });
  test('rejected HTML never proceeds to save or close', () async {
    var saves = 0;
    expect(
      await persistVisualEdit(
        read: () async => '<script>bad()</script>',
        accept: (_) => false,
        flush: () async {
          saves++;
          return true;
        },
      ),
      isFalse,
    );
    expect(saves, 0);
  });
  test('failed persistence keeps exit blocked and allows retry', () async {
    var attempts = 0;
    Future<bool> attempt() => persistVisualEdit(
      read: () async => '<p>draft</p>',
      accept: (_) => true,
      flush: () async => ++attempts > 1,
    );
    expect(await attempt(), isFalse);
    expect(await attempt(), isTrue);
  });
  test(
    'uninitialized editor still flushes parent title or source changes',
    () async {
      var saved = false;
      expect(
        await persistVisualEdit(
          read: () async => null,
          accept: (_) => throw StateError('unexpected'),
          flush: () async {
            saved = true;
            return true;
          },
        ),
        isTrue,
      );
      expect(saved, isTrue);
    },
  );
  test('snapshot errors do not report success or invoke persistence', () async {
    var saved = false;
    await expectLater(
      persistVisualEdit(
        read: () async => throw TimeoutException('snapshot'),
        accept: (_) => true,
        flush: () async {
          saved = true;
          return true;
        },
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(saved, isFalse);
  });
  testWidgets('save error updates visible banner and coalesces retry taps', (
    tester,
  ) async {
    final error = ValueNotifier<String?>(null);
    addTearDown(error.dispose);
    final pending = Completer<bool>();
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorSaveBanner(
            error: error,
            retry: () {
              retries++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    expect(find.byType(MaterialBanner), findsNothing);
    error.value = '保存到本地失败：磁盘空间不足';
    await tester.pump();
    expect(find.text(error.value!), findsOneWidget);
    await tester.tap(find.text('重试保存'));
    await tester.tap(find.text('重试保存'));
    await tester.pump();
    expect(retries, 1);
    expect(find.text('正在保存'), findsOneWidget);
    error.value = null;
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(MaterialBanner), findsNothing);
  });
  testWidgets('unexpected retry exception remains visible', (tester) async {
    final error = ValueNotifier<String?>('保存失败');
    addTearDown(error.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorSaveBanner(
            error: error,
            retry: () async {
              error.value = null;
              throw StateError('disk');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('操作失败，请重试'), findsOneWidget);
    expect(find.text('重试保存'), findsOneWidget);
  });
}
