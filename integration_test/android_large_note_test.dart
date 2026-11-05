import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/data/large_note_storage_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Android reads large notes without CursorWindow overflow',
    (_) async {
      expect(Platform.isAndroid, true);
      final root = await getTemporaryDirectory();
      await root.create(recursive: true);
      final directory = await root.createTemp('large-note-fixture-');
      final db = await AppDatabase.open(
        databasePath: '${directory.path}/fixture.sqlite',
      );
      try {
        await exerciseLargeNoteStorage(db);
      } finally {
        await db.raw.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
