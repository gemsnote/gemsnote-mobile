import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'file_cache_policy.dart';

class HistoryImageCache {
  HistoryImageCache(this.database, this.accountId);
  final Database database;
  final String accountId;
  static const schema = '''CREATE TABLE IF NOT EXISTS history_images (
    account_id TEXT NOT NULL, note_id TEXT NOT NULL, history_id TEXT NOT NULL,
    file_id TEXT NOT NULL, generation TEXT NOT NULL, bytes BLOB, cached_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(account_id, note_id, history_id, file_id),
    FOREIGN KEY(account_id, note_id, history_id) REFERENCES note_histories(account_id, note_id, history_id) ON DELETE CASCADE
  )''';

  Future<void> _requireSnapshot(
    DatabaseExecutor db,
    String noteId,
    String historyId,
    String content,
  ) async {
    final rows = await db.rawQuery(
      '''SELECT 1 FROM note_histories h JOIN notes n
      ON n.account_id=h.account_id AND n.server_id=h.note_id
      WHERE h.account_id=? AND h.note_id=? AND h.history_id=? AND h.content=? AND n.local_is_deleted=0''',
      [accountId, noteId, historyId, content],
    );
    if (rows.isEmpty) throw StateError('历史正文缓存已变化，请重新打开历史版本');
  }

  Future<Uint8List?> read(
    String noteId,
    String historyId,
    String fileId,
    String content,
  ) => database.transaction((txn) async {
    await _requireSnapshot(txn, noteId, historyId, content);
    final rows = await txn.query(
      'history_images',
      columns: ['bytes'],
      where: 'account_id=? AND note_id=? AND history_id=? AND file_id=?',
      whereArgs: [accountId, noteId, historyId, fileId],
    );
    return rows.isEmpty ? null : rows.single['bytes'] as Uint8List?;
  });

  Future<String> begin(
    String noteId,
    String historyId,
    String fileId,
    String content,
  ) => database.transaction((txn) async {
    await _requireSnapshot(txn, noteId, historyId, content);
    final generation = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await txn.insert('history_images', {
      'account_id': accountId,
      'note_id': noteId,
      'history_id': historyId,
      'file_id': fileId,
      'generation': generation,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return generation;
  });

  Future<void> complete(
    String noteId,
    String historyId,
    String fileId,
    String content,
    String generation,
    Uint8List bytes,
  ) => database.transaction((txn) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('invalidFileSize');
    }
    await _requireSnapshot(txn, noteId, historyId, content);
    final changed = await txn.update(
      'history_images',
      {'bytes': bytes, 'cached_at': DateTime.now().microsecondsSinceEpoch},
      where: 'account_id=? AND note_id=? AND history_id=? AND file_id=? AND generation=?',
      whereArgs: [accountId, noteId, historyId, fileId, generation],
    );
    if (changed != 1) throw StateError('图片缓存已清理或历史列表已更新，请重试');
    await enforceFileCacheBudget(txn);
  });

  /// A restored body can continue showing already downloaded historical images.
  Future<Uint8List?> restoredImage(String noteId, String fileId) async {
    final rows = await database.rawQuery(
      '''SELECT h.bytes FROM history_images h JOIN notes n
      ON n.account_id=h.account_id AND n.server_id=h.note_id
      WHERE h.account_id=? AND h.note_id=? AND h.file_id=? AND h.bytes IS NOT NULL AND n.local_is_deleted=0
      ORDER BY h.cached_at DESC LIMIT 1''',
      [accountId, noteId, fileId],
    );
    return rows.isEmpty ? null : rows.single['bytes'] as Uint8List?;
  }
}
