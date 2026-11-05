import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/services/account_file_cache.dart';

NoteFile file(int i) =>
    NoteFile(id: '$i', title: '$i', type: 'bin', isAttachment: i.isEven);

void main() {
  test(
    'all notes processed, bounded file concurrency, independent failures',
    () async {
      var active = 0;
      var maximum = 0;
      final lists = <String>[];
      final downloaded = <String>[];
      final reports = <List<int>>[];
      await AccountFileCache().run(
        ['a', 'bad', 'a', 'b'],
        listFiles: (id) async {
          lists.add(id);
          if (id == 'bad') throw StateError('offline');
          return List.generate(5, file);
        },
        download: (id, item) async {
          active++;
          if (active > maximum) maximum = active;
          downloaded.add('$id:${item.id}');
          await Future<void>.delayed(Duration.zero);
          active--;
          if (item.id == '2') throw StateError('failed');
        },
        onProgress: (n, f, e) => reports.add([n, f, e]),
      );
      expect(maximum, 3);
      expect(lists, ['a', 'bad', 'b']);
      expect(downloaded.toSet().length, 10);
      expect(reports.last, [3, 10, 3]);
    },
  );
  test('cancel while listing starts no file download or next note', () async {
    final queue = AccountFileCache();
    final gate = Completer<List<NoteFile>>();
    var lists = 0;
    var downloads = 0;
    final task = queue.run(
      ['a', 'b'],
      listFiles: (_) {
        lists++;
        return gate.future;
      },
      download: (_, _) async {
        downloads++;
      },
      onProgress: (_, _, _) {},
    );
    queue.cancel();
    gate.complete([file(1)]);
    await task;
    expect(lists, 1);
    expect(downloads, 0);
  });
  test('cancel drains in-flight writes before completing', () async {
    final queue = AccountFileCache();
    final gate = Completer<void>();
    final started = Completer<void>();
    var downloads = 0;
    var finished = false;
    final task = queue.run(
      ['a', 'b'],
      listFiles: (_) async => List.generate(8, file),
      download: (_, _) async {
        downloads++;
        if (downloads == 3) started.complete();
        await gate.future;
      },
      onProgress: (_, _, _) {},
    );
    task.then((_) => finished = true);
    await started.future;
    queue.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    gate.complete();
    await task;
    expect(downloads, 3);
    await expectLater(
      queue.run(
        [],
        listFiles: (_) async => [],
        download: (_, _) async {},
        onProgress: (_, _, _) {},
      ),
      throwsStateError,
    );
  });
  test('pre-cancelled queue performs no network activity', () async {
    final queue = AccountFileCache()..cancel();
    await queue.run(
      ['a'],
      listFiles: (_) async => throw StateError('must not list'),
      download: (_, _) async => fail('must not download'),
      onProgress: (_, _, _) {},
    );
  });
}
