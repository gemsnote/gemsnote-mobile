import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/sync_run_lease.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'foreground and background coordinators cannot enter together',
    () async {
      final database = await AppDatabase.open(
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(database.raw.close);
      final api = Api2Client();
      final foreground = SyncCoordinator(api, database);
      final background = SyncCoordinator(api, database);
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = foreground.runMetadataUpdate(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      await expectLater(
        background.runMetadataUpdate(() async => fail('overlapping action')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'syncInProgress',
          ),
        ),
      );
      release.complete();
      await first;
      await background.runMetadataUpdate(() async {});
    },
  );

  test(
    'expired lease is reclaimed but an old owner cannot release it',
    () async {
      final database = await AppDatabase.open(
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(database.raw.close);
      final first = SyncRunLease(database.raw);
      final original = await first.claim();
      expect(original, isNotNull);
      expect(await SyncRunLease(database.raw).claim(), isNull);
      await database.raw.update(
        'app_preferences',
        {'value': '$original:0'},
        where: 'name = ?',
        whereArgs: ['sync_run_lease'],
      );
      final replacement = await SyncRunLease(database.raw).claim();
      expect(replacement, isNotNull);
      expect(replacement, isNot(original));
      await first.release(original!);
      expect(await SyncRunLease(database.raw).claim(), isNull);
      await first.release(replacement!);
      expect(await SyncRunLease(database.raw).claim(), isNotNull);
    },
  );
}
