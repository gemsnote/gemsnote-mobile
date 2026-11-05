import 'dart:math';

import 'session_transition.dart';

import 'package:sqflite/sqflite.dart';

/// Coordinates sync and metadata writes across foreground/background engines.
/// A lease expires after process death so scheduled work can resume.
class SyncRunLease {
  SyncRunLease(this.database);

  final Database database;
  static const _name = 'sync_run_lease';
  static const _duration = Duration(minutes: 5);

  String _owner() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<String?> claim() => database.transaction((txn) async {
    final gate = await SessionTransition.read(txn, SessionTransition.gateKey);
    if (SessionTransition.alive(gate) &&
        (SessionTransition.currentOwner == null ||
            !gate.startsWith('${SessionTransition.currentOwner}:'))) {
      return null;
    }
    final rows = await txn.query(
      'app_preferences',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [_name],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rows.isNotEmpty) {
      final expiry = int.tryParse(
        (rows.single['value'] as String).split(':').last,
      );
      if (expiry != null && expiry > now) return null;
    }
    final owner = _owner();
    await txn.insert('app_preferences', {
      'name': _name,
      'value': '$owner:${now + _duration.inMilliseconds}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return owner;
  });

  Future<bool> renew(String owner) => database.transaction((txn) async {
    final rows = await txn.query(
      'app_preferences',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [_name],
    );
    if (rows.isEmpty ||
        !(rows.single['value'] as String).startsWith('$owner:')) {
      return false;
    }
    await txn.update(
      'app_preferences',
      {
        'value':
            '$owner:${DateTime.now().millisecondsSinceEpoch + _duration.inMilliseconds}',
      },
      where: 'name = ?',
      whereArgs: [_name],
    );
    return true;
  });

  Future<void> release(String owner) => database.delete(
    'app_preferences',
    where: 'name = ? AND value LIKE ?',
    whereArgs: [_name, '$owner:%'],
  );
}
