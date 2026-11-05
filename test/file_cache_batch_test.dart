import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/services/file_cache_batch.dart';

NoteFile file(int i) =>
    NoteFile(id: '$i', title: '$i', type: 'bin', isAttachment: i.isEven);

void main() {
  test('bounded workers drain queue and report failures without dropping other files', () async {
    var active = 0;
    var maximum = 0;
    final calls = <String>[];
    final progress = <FileCacheProgress>[];
    final result = await FileCacheBatch().run(
      List.generate(8, file),
      download: (item) async {
        active++;
        if (active > maximum) maximum = active;
        calls.add(item.id);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
        if (item.id == '2') throw StateError('network failure');
      },
      onProgress: progress.add,
    );
    expect(maximum, 3);
    expect(calls.toSet(), hasLength(8));
    expect(result.completed, 8);
    expect(result.failed.map((item) => item.id), ['2']);
    expect(result.cancelled, isFalse);
    expect(progress.first.completed, 0);
    expect(progress.last.completed, 8);
    expect(progress.last.failed, 1);
    final retried = <String>[];
    await FileCacheBatch().run(
      result.failed,
      download: (item) async {
        retried.add(item.id);
      },
    );
    expect(retried, ['2']);
  });

  test('cancel stops scheduling but waits for in-flight downloads', () async {
    final gate = Completer<void>();
    final batch = FileCacheBatch();
    var started = 0;
    var finished = false;
    final task = batch.run(
      List.generate(10, file),
      download: (_) async {
        started++;
        await gate.future;
      },
    );
    task.then((_) {
      finished = true;
    });
    expect(started, 3);
    batch.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    gate.complete();
    final result = await task;
    expect(started, 3);
    expect(result.completed, 3);
    expect(result.cancelled, isTrue);
    await expectLater(batch.run([], download: (_) async {}), throwsStateError);
  });

  test(
    'duplicates are downloaded once and pre-cancelled queue sends no requests',
    () async {
      var calls = 0;
      final result = await FileCacheBatch().run(
        [file(1), file(1)],
        download: (_) async {
          calls++;
        },
      );
      expect(result.completed, 1);
      expect(calls, 1);
      final cancelled = FileCacheBatch()..cancel();
      expect(
        (await cancelled.run(
          [file(2)],
          download: (_) async {
            calls++;
          },
        )).completed,
        0,
      );
      expect(calls, 1);
      expect(
        (await FileCacheBatch().run([], download: (_) async {})).completed,
        0,
      );
    },
  );
}
