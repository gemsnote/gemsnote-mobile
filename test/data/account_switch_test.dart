import 'dart:async';

import 'package:gemsnote/core/async/cancellation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

class FailingSessions extends MemorySessions {
  bool fail = false;
  @override
  Future<void> write(String userId, String token) async {
    if (fail) throw StateError('secureStorageUnavailable');
    await super.write(userId, token);
  }
}

class SnapshotSync extends SyncCoordinator {
  SnapshotSync(Api2Client api, this.db) : super(api, db);
  final AppDatabase db;
  @override
  Future<void> downloadFreshSnapshot({
    required Account account,
    required String token,
    SyncProgressCallback? onProgress,
  }) => db.replaceSnapshot(
    account: account,
    notebooks: [],
    notes: [],
    tags: [],
    lastSyncUsn: 0,
  );
}

void main() {
  late AppDatabase db;
  late FailingSessions sessions;
  late Api2Client api;
  late AuthRepository repo;
  Account account(String host, [String user = 'same-id']) => Account(
    userId: user,
    server: Uri.parse('https://$host/'),
    username: user,
    email: '',
    logo: '',
  );
  final a = account('a.test');
  final b = account('b.test');
  final c = account('a.test', 'other');
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    sessions = FailingSessions();
    api = Api2Client(
      httpClient: MockClient((_) => throw StateError('Switch must be offline')),
    );
    repo = AuthRepository(api, db, sessions, SyncCoordinator(api, db));
    for (final entry in [a, b, c]) {
      await db.replaceSnapshot(
        account: entry,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 9,
      );
      await sessions.write(entry.cacheKey, 'token-${entry.cacheKey}');
    }
    await db.activateCachedAccount(a);
  });
  tearDown(() => db.raw.close());

  test('switch keeps server/user isolation, drafts, tokens and restored active identity', () async {
    final draft = await db.createLocalNote(
      account: a,
      notebookId: '',
      isMarkdown: true,
      content: 'unsynced',
    );
    await db.setAutoCacheFiles(a.cacheKey, true);
    expect((await repo.savedAccounts()).map((a) => a.cacheKey).toSet(), {
      a.cacheKey,
      b.cacheKey,
      c.cacheKey,
    });
    final next = await repo.switchAccount(b.cacheKey);
    expect(next.account.cacheKey, b.cacheKey);
    expect(next.token, 'token-${b.cacheKey}');
    expect((await repo.restore())!.account.cacheKey, b.cacheKey);
    expect(await db.pendingNoteIds(a.cacheKey), {draft.noteId});
    expect(await db.notes(b.cacheKey), isEmpty);
    expect(await db.autoCacheFiles(b.cacheKey), false);
    await repo.switchAccount(a.cacheKey);
    expect((await db.dirtyNotes(a.cacheKey)).single.content, 'unsynced');
    expect(await db.autoCacheFiles(a.cacheKey), true);
    expect(sessions.values.length, 3);
    expect(await db.lastSyncUsn(a.cacheKey), 9);
  });
  test('missing session/account leaves active identity unchanged; logout hides account', () async {
    await sessions.delete(b.cacheKey);
    await expectLater(repo.switchAccount(b.cacheKey), throwsStateError);
    await expectLater(repo.switchAccount('missing'), throwsStateError);
    expect((await repo.restore())!.account.cacheKey, a.cacheKey);
    expect(
      (await repo.savedAccounts()).map((a) => a.cacheKey),
      isNot(contains(b.cacheKey)),
    );
    expect(await db.hasAccountCache(b.cacheKey), true);
  });
  test(
    'switch cancels and drains an old writer before activating another server',
    () async {
      final sync = SyncCoordinator(api, db);
      repo = AuthRepository(api, db, sessions, sync);
      final gate = Completer<void>();
      final started = Completer<void>();
      final operation = sync.runAttachmentUpload(() {
        started.complete();
        return gate.future;
      });
      final cancelled = expectLater(operation, throwsA(isA<SyncCancelled>()));
      await started.future;
      var switched = false;
      final switching = repo.switchAccount(b.cacheKey).then((value) {
        switched = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(switched, false);
      expect((await db.activeAccount())!.cacheKey, a.cacheKey);
      gate.complete();
      await cancelled;
      expect((await switching).account.cacheKey, b.cacheKey);
      expect(sync.isBusy, false);
    },
  );
  test('failed new login rolls back snapshot activation without losing previous drafts', () async {
    final d = account('new.test');
    await db.createLocalNote(
      account: a,
      notebookId: '',
      isMarkdown: true,
      content: 'keep',
    );
    repo = AuthRepository(api, db, sessions, SnapshotSync(api, db));
    sessions.fail = true;
    await expectLater(
      repo.completeLogin(
        PendingLogin(
          session: StoredSession(account: d, token: 'new-token'),
          hasCache: false,
        ),
        resetCache: false,
      ),
      throwsStateError,
    );
    expect((await repo.restore())!.account.cacheKey, a.cacheKey);
    expect((await db.dirtyNotes(a.cacheKey)).single.content, 'keep');
    expect(
      (await repo.savedAccounts()).map((a) => a.cacheKey),
      isNot(contains(d.cacheKey)),
    );
  });
}
