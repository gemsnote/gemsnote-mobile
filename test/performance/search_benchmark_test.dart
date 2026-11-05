import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Opt in with flutter test --dart-define=SEARCH_BENCHMARK=true
// test/performance/search_benchmark_test.dart. No hardware-dependent thresholds.
void main() {
  test('25,000-note on-disk substring search benchmark', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('gemsnote-search-');
    final db = await AppDatabase.open(
      databasePath: '${directory.path}/notes.db',
    );
    addTearDown(() async {
      await db.raw.close();
      await directory.delete(recursive: true);
    });
    final account = Account(
      userId: 'bench',
      server: Uri.parse('https://example.test/'),
      username: '',
      email: '',
      logo: '',
    );
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      tags: [],
      lastSyncUsn: 1,
      notes: [
        Note.fromJson({'NoteId': '0', 'Title': 'common 0'}),
      ],
    );
    final template = (await db.raw.query('notes')).single;
    final body = 'x' * 4096;
    await db.raw.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 1; i < 25000; i++) {
        batch.insert('notes', {
          ...template,
          'server_id': '$i',
          'title': 'common $i',
          'content': '$body ${i % 100 == 0 ? '中文关键词 rare' : ''}',
          'updated_time': '${25000 - i}'.padLeft(6, '0'),
        });
      }
      await batch.commit(noResult: true);
    });
    for (final query in ['common', 'rare', '中文', 'absent', '%_']) {
      final times = <int>[];
      for (var i = 0; i < 6; i++) {
        final timer = Stopwatch()..start();
        final results = await db.searchNoteSummaries(
          account.cacheKey,
          query,
          limit: 1001,
        );
        times.add(timer.elapsedMilliseconds);
        expect(
          results.length,
          query == 'common'
              ? 1001
              : {'rare', '中文'}.contains(query)
              ? 249
              : 0,
        );
      }
      // ignore: avoid_print
      print('SEARCH_BENCHMARK query=$query milliseconds=$times');
    }
    final full = await db.searchNotes(account.cacheKey, 'common', limit: 1001);
    // ignore: avoid_print
    print(
      'SEARCH_BENCHMARK bodyCharsAvoided=${full.fold<int>(0, (sum, note) => sum + note.content.length)}',
    );
  }, skip: !const bool.fromEnvironment('SEARCH_BENCHMARK'));
}
