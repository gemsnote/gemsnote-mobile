import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// Android's CursorWindow may be only 2 MiB. A LIMIT on rows cannot make one
/// large body fit. Project bounded values, then reconstruct oversized fields
/// in byte chunks inside the same transaction so concurrent writes cannot mix.
extension LargeValueQuery on DatabaseExecutor {
  static const chunkBytes = 256 * 1024;
  static const _fields = <String, Set<String>>{
    'notes': {'content'},
    'shared_notes': {'content', 'metadata'},
    'note_histories': {'content'},
    'note_create_attempts': {'payload'},
  };

  Future<List<Map<String, Object?>>> queryLargeValues(
    String table, {
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final fields = _fields[table] ?? const <String>{};
    final selected = fields
        .where((f) => columns == null || columns.contains(f))
        .toList();
    if (selected.isEmpty) {
      return query(
        table,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );
    }
    if (this is Database) {
      return (this as Database).transaction(
        (tx) => tx.queryLargeValues(
          table,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          orderBy: orderBy,
          limit: limit,
          offset: offset,
        ),
      );
    }
    final names =
        columns ??
        (await rawQuery('PRAGMA table_info("$table")'))
            .map((r) => r['name']! as String)
            .toList();
    final projection = <String>[
      for (final name in names)
        if (selected.contains(name))
          'CASE WHEN length(CAST("$name" AS BLOB)) <= $chunkBytes '
              'THEN "$name" ELSE NULL END AS "$name"'
        else
          '"$name"',
      'rowid AS __large_rowid',
      for (final name in selected)
        'CASE WHEN length(CAST("$name" AS BLOB)) > $chunkBytes '
            'THEN length(CAST("$name" AS BLOB)) ELSE 0 END AS __large_size_$name',
    ];
    final rows = await query(
      table,
      columns: projection,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    final result = <Map<String, Object?>>[];
    for (final source in rows) {
      final row = Map<String, Object?>.from(source);
      final id = row.remove('__large_rowid');
      for (final name in selected) {
        final size = row.remove('__large_size_$name')! as int;
        if (size == 0) continue;
        final bytes = BytesBuilder(copy: false);
        for (var start = 0; start < size; start += chunkBytes) {
          final parts = await rawQuery(
            'SELECT substr(CAST("$name" AS BLOB), ?, ?) AS chunk '
            'FROM "$table" WHERE rowid = ?',
            [start + 1, chunkBytes, id],
          );
          if (parts.length != 1 || parts.single['chunk'] is! Uint8List) {
            throw StateError('localValueReadFailed');
          }
          bytes.add(parts.single['chunk']! as Uint8List);
        }
        if (bytes.length != size) throw StateError('localValueReadFailed');
        // Decode only after joining bytes: UTF-8 characters and embedded NULs
        // must survive chunk boundaries without truncation or replacement.
        row[name] = utf8.decode(bytes.takeBytes());
      }
      result.add(row);
    }
    return result;
  }
}
