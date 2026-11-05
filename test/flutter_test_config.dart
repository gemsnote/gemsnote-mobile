import 'dart:async';

import 'package:workmanager/workmanager.dart';

// Widget tests simulate Android UI on a Linux/macOS host. Do not let the plugin
// launch real host processes (e.g. systemctl) when the workspace cancels jobs.
// Scheduling tests install their own recording implementation explicitly.
class _HostIsolatedScheduler extends WorkmanagerPlatform {
  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {}

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async {}

  @override
  Future<void> registerProcessingTask(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
    Map<String, dynamic>? inputData,
    Constraints? constraints,
  }) async {}

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {}
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Workmanager(); // Complete the facade's lazy platform registration first.
  WorkmanagerPlatform.instance = _HostIsolatedScheduler();
  await testMain();
}
