import 'dart:async';

import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:gemsnote/core/async/cancellation.dart';
import 'package:gemsnote/l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/sync_progress_dialog.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets('cancel uses $language and waits for work and cleanup', (
      tester,
    ) async {
      final work = Completer<void>();
      final cleanup = Completer<void>();
      var cancels = 0;
      Object? received;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            AppStrings.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                try {
                  await showSyncProgress(
                    context,
                    synchronize: (_) => work.future,
                    cancel: () {
                      cancels++;
                      return cleanup.future;
                    },
                  );
                } on Object catch (error) {
                  received = error;
                }
              },
              child: const Text('start'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final cancel = find.text(language == 'zh' ? '取消同步' : 'Cancel sync');
      await tester.tap(cancel);
      await tester.pump();
      expect(
        find.text(language == 'zh' ? '正在取消同步…' : 'Cancelling sync…'),
        findsOneWidget,
      );
      await tester.tap(cancel);
      expect(cancels, 1);
      work.completeError(const SyncCancelled());
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      cleanup.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(received, isA<SyncCancelled>());
    });
  }

  testWidgets('progress updates, blocks dismissal and closes on success', (
    tester,
  ) async {
    final completion = Completer<void>();
    late SyncProgressCallback progress;
    var starts = 0;
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  await showSyncProgress(
                    context,
                    synchronize: (callback) {
                      starts++;
                      progress = callback;
                      return completion.future;
                    },
                  );
                  finished = true;
                },
                child: const Text('同步'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('同步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在准备同步…'), findsOneWidget);
    progress(SyncProgress(SyncStage.uploading, 2));
    await tester.pump();
    expect(find.text('正在上传本地修改，已上传 2 篇'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(finished, isFalse);
    for (final entry in {
      SyncStage.notebooks: '正在下载笔记本，已接收 3 个',
      SyncStage.notes: '正在下载笔记正文，已接收 3 篇',
      SyncStage.tags: '正在下载标签，已接收 3 个',
      SyncStage.saving: '正在保存本地数据…',
    }.entries) {
      progress(SyncProgress(entry.key, 3));
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
    }
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(starts, 1);
    expect(finished, isTrue);
  });

  testWidgets('failure closes dialog and propagates to caller', (tester) async {
    final error = StateError('offline');
    Object? received;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  try {
                    await showSyncProgress(
                      context,
                      synchronize: (_) async => throw error,
                    );
                  } on Object catch (value) {
                    received = value;
                  }
                },
                child: const Text('同步'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('同步'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(received, same(error));
  });
}
