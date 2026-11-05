import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/services/background_tasks.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workmanager/workmanager.dart';

class RecordingScheduler extends WorkmanagerPlatform {
  final processing =
      <({String id, String task, Duration? delay, Constraints? constraints})>[];
  final cancelled = <String>[];

  @override
  Future<void> registerProcessingTask(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
    Map<String, dynamic>? inputData,
    Constraints? constraints,
  }) async {
    expect(inputData, isNull, reason: 'Credentials stay in secure storage');
    processing.add((
      id: uniqueName,
      task: taskName,
      delay: initialDelay,
      constraints: constraints,
    ));
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelled.add(uniqueName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Construct the facade before replacing its lazily registered platform.
  Workmanager();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  late WorkmanagerPlatform original;
  late RecordingScheduler scheduler;
  setUp(() {
    original = WorkmanagerPlatform.instance;
    scheduler = RecordingScheduler();
    WorkmanagerPlatform.instance = scheduler;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    WorkmanagerPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'iOS recurrence uses active account preferences without needing a token',
    () async {
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      expect(await prepareIOSBackgroundRun(db, sync: true), isFalse);
      final account = Account(
        userId: '507f1f77bcf86cd799439011',
        server: Uri.parse('https://background-test.invalid'),
        username: 'background-test',
        email: '',
        logo: '',
      );
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 0,
      );
      expect(await prepareIOSBackgroundRun(db, sync: true), isFalse);
      expect(await prepareIOSBackgroundRun(db, sync: false), isFalse);
      expect(scheduler.processing, isEmpty);
      await db.setAutoSync(account.cacheKey, true);
      expect(await prepareIOSBackgroundRun(db, sync: true), isTrue);
      expect(await prepareIOSBackgroundRun(db, sync: false), isFalse);
      await db.setAutoCacheFiles(account.cacheKey, true);
      expect(await prepareIOSBackgroundRun(db, sync: false), isTrue);
      expect(scheduler.processing.map((task) => task.id), [
        iosSyncTask,
        iosCacheTask,
      ]);
      await db.deactivate(account.cacheKey);
      expect(await prepareIOSBackgroundRun(db, sync: true), isFalse);
      expect(scheduler.processing, hasLength(2));
    },
  );

  test(
    'iOS queues distinct network-constrained processing opportunities',
    () async {
      await BackgroundResourceCache.setEnabled(true);
      await BackgroundNoteSync.setEnabled(true);
      expect(scheduler.processing.map((task) => task.id), [
        iosCacheTask,
        iosSyncTask,
      ]);
      for (final task in scheduler.processing) {
        // iOS dispatches the identifier, unlike Android's separate task name.
        expect(task.task, task.id);
        expect(task.delay, const Duration(minutes: 15));
        expect(task.constraints?.networkType, NetworkType.connected);
      }
    },
  );

  test(
    'iOS handoff reuses identifiers and removes the minimum delay',
    () async {
      await BackgroundResourceCache.resumeOnce();
      await BackgroundNoteSync.resumeOnce();
      expect(scheduler.processing.map((task) => task.id), [
        iosCacheTask,
        iosSyncTask,
      ]);
      expect(
        scheduler.processing.every((task) => task.delay == Duration.zero),
        isTrue,
      );
    },
  );

  test('disabling preferences cancels each pending iOS task', () async {
    await BackgroundResourceCache.setEnabled(false);
    await BackgroundNoteSync.setEnabled(false);
    expect(scheduler.cancelled, [iosCacheTask, iosSyncTask]);
    expect(scheduler.processing, isEmpty);
  });

  test(
    'Android cancellation retains periodic and handoff identifiers',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await BackgroundResourceCache.setEnabled(false);
      await BackgroundNoteSync.setEnabled(false);
      expect(scheduler.cancelled, [
        'gemsnote.resourceCache.periodic',
        'gemsnote.resourceCache.resume',
        'gemsnote.noteSync.periodic',
        'gemsnote.noteSync.resume',
      ]);
      expect(scheduler.processing, isEmpty);
    },
  );

  test('desktop does not schedule mobile background work', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await BackgroundResourceCache.initialize();
    await BackgroundResourceCache.setEnabled(true);
    await BackgroundResourceCache.resumeOnce();
    await BackgroundNoteSync.setEnabled(true);
    await BackgroundNoteSync.resumeOnce();
    expect(scheduler.processing, isEmpty);
    expect(scheduler.cancelled, isEmpty);
  });
}
