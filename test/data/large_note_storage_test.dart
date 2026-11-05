import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'large_note_storage_scenario.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
    'large note bodies survive every local read and sharing refresh',
    () async {
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      try {
        await exerciseLargeNoteStorage(db);
      } finally {
        await db.raw.close();
      }
    },
  );
}
