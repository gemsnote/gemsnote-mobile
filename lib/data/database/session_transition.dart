import 'dart:async';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// A short-lived, renewable gate prevents foreground/background sync from
/// starting while credentials and the active account are being replaced.
class SessionTransition {
  SessionTransition(this.database);
  final Database database;
  static const gateKey = 'session_transition';
  static const epochKey = 'session_epoch';
  static final zoneKey = Object();
  static final expectedEpochKey = Object();
  static String? get expectedEpoch => Zone.current[expectedEpochKey] as String?;
  static String? get currentOwner => Zone.current[zoneKey] as String?;
  static const duration = Duration(minutes: 5);

  static Future<String> read(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'app_preferences',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? '' : rows.single['value'] as String;
  }

  static Future<void> write(
    DatabaseExecutor db,
    String key,
    String value,
  ) async {
    await db.insert('app_preferences', {
      'name': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static bool alive(String value) =>
      value.isNotEmpty &&
      (int.tryParse(value.split(':').last) ?? 0) >
          DateTime.now().millisecondsSinceEpoch;

  Future<String> begin() => database.transaction((tx) async {
    if (alive(await read(tx, gateKey))) {
      throw StateError('sessionChangeInProgress');
    }
    final owner = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await write(
      tx,
      gateKey,
      '$owner:${DateTime.now().millisecondsSinceEpoch + duration.inMilliseconds}',
    );
    // An old worker must not resume even if the user returns to the same account.
    await write(tx, epochKey, owner);
    return owner;
  });
  Future<void> renew(String owner) => database.transaction((tx) async {
    if (!(await read(tx, gateKey)).startsWith('$owner:')) {
      throw StateError('sessionChangeInProgress');
    }
    await write(
      tx,
      gateKey,
      '$owner:${DateTime.now().millisecondsSinceEpoch + duration.inMilliseconds}',
    );
  });
  Future<void> release(String owner) async {
    await database.delete(
      'app_preferences',
      where: 'name = ? AND value LIKE ?',
      whereArgs: [gateKey, '$owner:%'],
    );
  }
}
