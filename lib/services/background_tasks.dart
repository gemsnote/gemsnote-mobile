import 'dart:ui';
import 'dart:async';

import '../core/async/cancellation.dart';
import '../data/database/session_transition.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../core/api/api2_client.dart';
import '../data/database/app_database.dart';
import '../data/session/session_store.dart';
import '../repositories/auth_repository.dart';
import '../sync/sync_coordinator.dart';

const _taskName = 'gemsnote.resourceCache';
const _periodicName = 'gemsnote.resourceCache.periodic';
const _resumeName = 'gemsnote.resourceCache.resume';
const _syncTaskName = 'gemsnote.noteSync';
const _syncPeriodicName = 'gemsnote.noteSync.periodic';
const _syncResumeName = 'gemsnote.noteSync.resume';
const iosCacheTask = 'com.github.gemsnote.resourceCache';
const iosSyncTask = 'com.github.gemsnote.noteSync';

bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;
bool get _android => defaultTargetPlatform == TargetPlatform.android;

@pragma('vm:entry-point')
void backgroundCacheDispatcher() {
  Workmanager().executeTask((taskName, _) async {
    final cache = taskName == _taskName || taskName == iosCacheTask;
    final sync = taskName == _syncTaskName || taskName == iosSyncTask;
    if (!cache && !sync) return true;
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return cache ? runBackgroundResourceCache() : runBackgroundNoteSync();
  });
}

/// Rechecks the active account and its preference inside the worker isolate.
/// SyncCoordinator takes a SQLite lease shared with the foreground engine.
Future<bool> runBackgroundNoteSync() async {
  final database = await AppDatabase.open();
  try {
    if (_ios && !await prepareIOSBackgroundRun(database, sync: true)) {
      return true;
    }
    final api = Api2Client();
    final repository = AuthRepository(
      api,
      database,
      const SecureSessionStore(),
      SyncCoordinator(api, database),
    );
    final epoch = await SessionTransition.read(
      database.raw,
      SessionTransition.epochKey,
    );
    final session = await repository.restore();
    if (session == null || !await repository.autoSync(session)) return true;
    await runZoned(
      () => repository.synchronize(session),
      zoneValues: {SessionTransition.expectedEpochKey: epoch},
    );
    return true;
  } on SyncCancelled {
    return true;
  } on PendingVisualImage {
    // The original image must be supplied from the editor before a later run.
    return true;
  } on StateError catch (error) {
    if (error.message == 'syncInProgress' ||
        error.message == 'sessionChangeInProgress') {
      return true;
    }
    return false;
  } on Object {
    return false;
  } finally {
    await database.raw.close();
  }
}

/// Runs only for the account that is still active when the task starts. The
/// durable queue owns a SQLite lease, so a foreground runner cannot overlap.
Future<bool> runBackgroundResourceCache() async {
  final database = await AppDatabase.open();
  try {
    if (_ios && !await prepareIOSBackgroundRun(database, sync: false)) {
      return true;
    }
    final api = Api2Client();
    final repository = AuthRepository(
      api,
      database,
      const SecureSessionStore(),
      SyncCoordinator(api, database),
    );
    final epoch = await SessionTransition.read(
      database.raw,
      SessionTransition.epochKey,
    );
    final session = await repository.restore();
    if (session == null || !await repository.autoCacheFiles(session)) {
      return true;
    }
    final queue = repository.fileCacheQueue(session);
    Future<void> checkAccount() async {
      final active = await database.activeAccount();
      if (epoch !=
              await SessionTransition.read(
                database.raw,
                SessionTransition.epochKey,
              ) ||
          SessionTransition.alive(
            await SessionTransition.read(
              database.raw,
              SessionTransition.gateKey,
            ),
          ) ||
          active?.cacheKey != session.account.cacheKey ||
          !await repository.autoCacheFiles(session)) {
        queue.cancel();
        throw const SyncCancelled();
      }
    }

    Future<void>? checking;
    final watcher = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (checking != null) return;
      checking = checkAccount()
          .catchError((Object _) {
            queue.cancel();
          })
          .whenComplete(() {
            checking = null;
          });
    });
    try {
      await checkAccount();
      await queue.run(
        (await repository.notes(session.account.cacheKey))
            .where((note) => note.usn > 0)
            .map((note) => note.noteId)
            .toList(),
        listFiles: (id) async {
          await checkAccount();
          return repository.noteFiles(session, id);
        },
        download: (id, file) async {
          await checkAccount();
          if (file.isAttachment) {
            await repository.noteAttachment(session, id, file);
          } else {
            await repository.noteImage(session, id, file);
          }
        },
        onProgress: (_, _, _) {},
      );
    } finally {
      watcher.cancel();
      await checking;
    }
    if (queue.cancelled) return true;
    final active = await database.activeAccount();
    if (active?.cacheKey != session.account.cacheKey ||
        !await repository.autoCacheFiles(session)) {
      return true;
    }
    final status = await repository.downloadQueueStatus(session);
    return status.failed == 0;
  } on SyncCancelled {
    return true;
  } on Object {
    return false;
  } finally {
    await database.raw.close();
  }
}

// BGProcessing requests run once. Requeue before accessing the Keychain or
// network: a locked device or expired execution window must not permanently
// stop future opportunities. Each run still checks the live account and flags.
@visibleForTesting
Future<bool> prepareIOSBackgroundRun(
  AppDatabase database, {
  required bool sync,
}) async {
  final account = await database.activeAccount();
  if (account == null) return false;
  final enabled = sync
      ? await database.autoSync(account.cacheKey)
      : await database.autoCacheFiles(account.cacheKey);
  if (!enabled) return false;
  if (sync) {
    await BackgroundNoteSync.setEnabled(true);
  } else {
    await BackgroundResourceCache.setEnabled(true);
  }
  return true;
}

class BackgroundResourceCache {
  const BackgroundResourceCache._();

  static Future<void> initialize() async {
    if (!_android && !_ios) return;
    await Workmanager().initialize(backgroundCacheDispatcher);
  }

  static Future<void> setEnabled(bool enabled) async {
    if (_ios) {
      if (enabled) {
        await _scheduleIOS(iosCacheTask, const Duration(minutes: 15));
      } else {
        await Workmanager().cancelByUniqueName(iosCacheTask);
      }
      return;
    }
    if (!_android) return;
    if (enabled) {
      await Workmanager().registerPeriodicTask(
        _periodicName,
        _taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } else {
      await Workmanager().cancelByUniqueName(_periodicName);
      await Workmanager().cancelByUniqueName(_resumeName);
    }
  }

  static Future<void> resumeOnce() async {
    if (_ios) return _scheduleIOS(iosCacheTask, Duration.zero);
    if (!_android) return;
    await Workmanager().registerOneOffTask(
      _resumeName,
      _taskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }
}

class BackgroundNoteSync {
  const BackgroundNoteSync._();

  static Future<void> setEnabled(bool enabled) async {
    if (_ios) {
      if (enabled) {
        await _scheduleIOS(iosSyncTask, const Duration(minutes: 15));
      } else {
        await Workmanager().cancelByUniqueName(iosSyncTask);
      }
      return;
    }
    if (!_android) return;
    if (enabled) {
      await Workmanager().registerPeriodicTask(
        _syncPeriodicName,
        _syncTaskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } else {
      await Workmanager().cancelByUniqueName(_syncPeriodicName);
      await Workmanager().cancelByUniqueName(_syncResumeName);
    }
  }

  static Future<void> resumeOnce() async {
    if (_ios) return _scheduleIOS(iosSyncTask, Duration.zero);
    if (!_android) return;
    await Workmanager().registerOneOffTask(
      _syncResumeName,
      _syncTaskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }
}

Future<void> _scheduleIOS(String identifier, Duration delay) =>
    Workmanager().registerProcessingTask(
      identifier,
      identifier,
      initialDelay: delay,
      constraints: Constraints(networkType: NetworkType.connected),
    );
