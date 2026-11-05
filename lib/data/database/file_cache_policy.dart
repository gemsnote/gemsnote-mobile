import 'package:sqflite/sqflite.dart';

/// One binary-cache budget across accounts and both current/historical images.
Future<void> enforceFileCacheBudget(DatabaseExecutor database) async {
  final rows = await database.rawQuery('''
    SELECT 'note_files' AS source, rowid AS id, length(bytes) AS size, cached_at FROM note_files WHERE bytes IS NOT NULL
    UNION ALL
    SELECT 'history_images' AS source, rowid AS id, length(bytes) AS size, cached_at FROM history_images WHERE bytes IS NOT NULL
    UNION ALL
    SELECT 'shared_files' AS source, rowid AS id, length(bytes) AS size, cached_at FROM shared_files WHERE bytes IS NOT NULL
    ORDER BY cached_at DESC, source, id DESC
  ''');
  var total = 0;
  for (final row in rows) {
    total += row['size'] as int;
    if (total > 64 * 1024 * 1024) {
      await database.update(
        row['source']! as String,
        {'bytes': null},
        where: 'rowid = ?',
        whereArgs: [row['id']],
      );
    }
  }
}
