import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/file_cache_usage.dart';
import 'package:gemsnote/ui/file_cache_dialog.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required Future<FileCacheUsage> Function() load,
    required Future<void> Function() clear,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => FileCacheDialog(
                accountLabel: 'user · server',
                load: load,
                clear: clear,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'clear requires confirmation, cancellation preserves cache, pending clear blocks duplicates',
    (tester) async {
      var calls = 0;
      final pending = Completer<void>();
      await mount(
        tester,
        load: () async => const FileCacheUsage(files: 2, bytes: 1024),
        clear: () {
          calls++;
          return pending.future;
        },
      );
      expect(find.text('2 个文件 · 1.0 KiB'), findsOneWidget);
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pump();
      await tester.tap(find.text('确认清理'));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('离线资源缓存已清理'), findsOneWidget);
      expect(find.text('0 个文件 · 0 B'), findsOneWidget);
      expect(find.text('清理缓存'), findsNothing);
    },
  );

  testWidgets('pending tasks can be cleared even without cached bytes', (
    tester,
  ) async {
    var clears = 0;
    await mount(
      tester,
      load: () async =>
          const FileCacheUsage(files: 0, bytes: 0, pendingDownloads: 2),
      clear: () async {
        clears++;
      },
    );
    expect(find.text('待处理资源下载：2 篇笔记'), findsOneWidget);
    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    expect(clears, 0);
    await tester.tap(find.text('确认清理'));
    await tester.pumpAndSettle();
    expect(clears, 1);
    expect(find.textContaining('待处理资源下载：'), findsNothing);
  });

  testWidgets(
    'read and clear failures remain retryable without false success',
    (tester) async {
      var readFail = true;
      var clearFail = true;
      await mount(
        tester,
        load: () async {
          if (readFail) throw StateError('read failure');
          return const FileCacheUsage(files: 1, bytes: 0);
        },
        clear: () async {
          if (clearFail) throw StateError('write failure');
        },
      );
      expect(find.text('读取缓存用量失败，请重试'), findsOneWidget);
      readFail = false;
      await tester.tap(find.text('重试读取'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(find.text('清理缓存失败，请重试'), findsOneWidget);
      expect(find.text('离线资源缓存已清理'), findsNothing);
      clearFail = false;
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(find.text('离线资源缓存已清理'), findsOneWidget);
    },
  );
}
