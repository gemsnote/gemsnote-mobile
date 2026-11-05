import '../core/api/api2_client.dart';
import '../data/database/app_database.dart';
import '../data/session/session_store.dart';
import '../repositories/auth_repository.dart';
import '../sync/sync_coordinator.dart';
import 'background_tasks.dart';

/// Independent local services start together, after the startup frame is drawn.
/// Wait for both before exposing actions that can schedule background work.
Future<AuthRepository> initializeApplication({
  Future<AppDatabase> Function()? openDatabase,
  Future<void> Function()? initializeBackground,
}) async {
  AppDatabase? database;
  try {
    await Future.wait<void>([
      Future.sync(initializeBackground ?? BackgroundResourceCache.initialize),
      Future.sync(openDatabase ?? AppDatabase.open).then((value) {
        database = value;
      }),
    ]);
    final api = Api2Client();
    return AuthRepository(
      api,
      database!,
      const SecureSessionStore(),
      SyncCoordinator(api, database!),
    );
  } on Object {
    // Future.wait waits for both tasks before throwing; do not leave an open
    // database behind when the scheduler fails and the user chooses to retry.
    await database?.raw.close();
    rethrow;
  }
}
