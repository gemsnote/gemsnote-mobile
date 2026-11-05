import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../domain/models/shared_file.dart';
import '../../domain/models/shared_note.dart';
import 'file_cache_policy.dart';

class SharedFileCache {
  SharedFileCache(this.database, this.accountId);
  final Database database;
  final String accountId;
  static const schema = '''CREATE TABLE IF NOT EXISTS shared_files (
    account_id TEXT NOT NULL, note_id TEXT NOT NULL, file_id TEXT NOT NULL,
    kind TEXT NOT NULL, version TEXT NOT NULL, size INTEGER NOT NULL,
    generation TEXT NOT NULL, bytes BLOB, cached_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(account_id, note_id, file_id),
    FOREIGN KEY(account_id, note_id) REFERENCES shared_notes(account_id, note_id) ON DELETE CASCADE
  )''';

  static String _generation() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Future<void> replace(
    DatabaseExecutor txn,
    String accountId,
    SharedNote note, {
    required bool preserve,
  }) async {
    final rows = await txn.query(
      'shared_files',
      columns: ['file_id', 'kind', 'version', 'size'],
      where: 'account_id=? AND note_id=?',
      whereArgs: [accountId, note.note.noteId],
    );
    final old = {for (final row in rows) row['file_id']: row};
    final ids = note.files.map((file) => file.fileId).toSet();
    if (ids.length != note.files.length ||
        note.files.any((file) => file.noteId != note.note.noteId)) {
      throw StateError('invalidSharedFiles');
    }
    for (final row in rows) {
      if (!ids.contains(row['file_id'])) {
        await txn.delete(
          'shared_files',
          where: 'account_id=? AND note_id=? AND file_id=?',
          whereArgs: [accountId, note.note.noteId, row['file_id']],
        );
      }
    }
    for (final file in note.files) {
      final row = old[file.fileId];
      final unchanged =
          preserve &&
          row != null &&
          row['kind'] == file.kind &&
          row['version'] == file.version &&
          row['size'] == file.size;
      final values = <String, Object?>{
        'kind': file.kind,
        'version': file.version,
        'size': file.size,
        'generation': _generation(),
        if (!unchanged) 'bytes': null,
        if (!unchanged) 'cached_at': 0,
      };
      if (row == null) {
        await txn.insert('shared_files', {
          'account_id': accountId,
          'note_id': file.noteId,
          'file_id': file.fileId,
          ...values,
        });
      } else {
        await txn.update(
          'shared_files',
          values,
          where: 'account_id=? AND note_id=? AND file_id=?',
          whereArgs: [accountId, file.noteId, file.fileId],
        );
      }
    }
  }

  Future<Map<String, Object?>> _row(
    DatabaseExecutor txn,
    SharedNote note,
    SharedFile file, {
    required bool includeBytes,
  }) async {
    final rows = await txn.rawQuery(
      '''SELECT f.generation${includeBytes ? ', f.bytes' : ''} FROM shared_files f JOIN shared_notes n
      ON n.account_id=f.account_id AND n.note_id=f.note_id
      WHERE f.account_id=? AND f.note_id=? AND f.file_id=? AND f.kind=? AND f.version=? AND f.size=?
      AND n.owner_id=? AND n.version=?''',
      [
        accountId,
        file.noteId,
        file.fileId,
        file.kind,
        file.version,
        file.size,
        note.note.userId,
        note.version,
      ],
    );
    if (file.noteId != note.note.noteId || rows.isEmpty) {
      throw StateError('共享资源缓存已失效，请刷新列表');
    }
    return rows.single;
  }

  Future<Uint8List?> read(SharedNote note, SharedFile file) async =>
      (await _row(database, note, file, includeBytes: true))['bytes']
          as Uint8List?;

  Future<String> begin(SharedNote note, SharedFile file) async =>
      (await _row(database, note, file, includeBytes: false))['generation']!
          as String;

  Future<void> complete(
    SharedNote note,
    SharedFile file,
    String generation,
    Uint8List bytes,
  ) => database.transaction((txn) async {
    if (bytes.length != file.size || bytes.length > file.maxBytes) {
      throw StateError('invalidFileSize');
    }
    final row = await _row(txn, note, file, includeBytes: false);
    if (row['generation'] != generation) throw StateError('共享缓存已清理或列表已刷新');
    await txn.update(
      'shared_files',
      {'bytes': bytes, 'cached_at': DateTime.now().microsecondsSinceEpoch},
      where: 'account_id=? AND note_id=? AND file_id=?',
      whereArgs: [accountId, file.noteId, file.fileId],
    );
    await enforceFileCacheBudget(txn);
  });

  Future<void> invalidate(SharedFile file) async {
    await database.update(
      'shared_files',
      {'bytes': null, 'cached_at': 0, 'generation': _generation()},
      where: 'account_id=? AND note_id=? AND file_id=? AND version=?',
      whereArgs: [accountId, file.noteId, file.fileId, file.version],
    );
  }

  static Future<void> clear(DatabaseExecutor txn, String accountId) async {
    await txn.update(
      'shared_files',
      {'bytes': null, 'cached_at': 0, 'generation': _generation()},
      where: 'account_id=?',
      whereArgs: [accountId],
    );
  }
}
