import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/shared_note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

void main() {
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  final shared = SharedNote.fromJson({
    'NoteId': '507f1f77bcf86cd799439011',
    'OwnerUserId': '507f1f77bcf86cd799439012',
    'Title': 'Shared',
    'IsMarkdown': true,
    'Version': List.filled(64, 'a').join(),
  });
  late AppDatabase db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 8,
    );
    await db.replaceSharedSnapshot(account.cacheKey, [shared]);
  });
  tearDown(() => db.raw.close());

  test('offline content is isolated, supports empty body, never enters personal uploads', () async {
    await expectLater(
      db.cachedSharedContent(account.cacheKey, shared),
      throwsStateError,
    );
    await db.cacheSharedContent(account.cacheKey, shared, '');
    expect(
      (await db.cachedSharedContent(account.cacheKey, shared)).content,
      '',
    );
    expect(await db.cachedSharedNotes('another-account'), isEmpty);
    await expectLater(
      db.cachedSharedContent('another-account', shared),
      throwsStateError,
    );
    expect(await db.notes(account.cacheKey), isEmpty);
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
    expect(await db.lastSyncUsn(account.cacheKey), 8);
    await db.deactivate(account.cacheKey);
    expect(await db.cachedSharedNotes(account.cacheKey), hasLength(1));
  });
  test('snapshot retains unchanged body, invalidates changed body, deletes revoked items', () async {
    await db.cacheSharedContent(account.cacheKey, shared, 'old');
    final renamed = SharedNote(
      note: shared.note.copyWith(title: 'Renamed'),
      version: shared.version,
    );
    await db.replaceSharedSnapshot(account.cacheKey, [renamed]);
    expect(
      (await db.cachedSharedContent(account.cacheKey, shared)).title,
      'Renamed',
    );
    final changed = SharedNote(
      note: shared.note,
      version: List.filled(64, 'b').join(),
    );
    await db.replaceSharedSnapshot(account.cacheKey, [changed]);
    await expectLater(
      db.cachedSharedContent(account.cacheKey, changed),
      throwsStateError,
    );
    await expectLater(
      db.cacheSharedContent(account.cacheKey, shared, 'late body'),
      throwsStateError,
    );
    await db.replaceSharedSnapshot(account.cacheKey, []);
    await expectLater(
      db.cacheSharedContent(account.cacheKey, changed, 'late after revoke'),
      throwsStateError,
    );
    expect(await db.cachedSharedNotes(account.cacheKey), isEmpty);
  });
  test('duplicate snapshot is rejected without clearing valid cache', () async {
    await db.cacheSharedContent(account.cacheKey, shared, 'safe');
    await expectLater(
      db.replaceSharedSnapshot(account.cacheKey, [shared, shared]),
      throwsStateError,
    );
    expect(
      (await db.cachedSharedContent(account.cacheKey, shared)).content,
      'safe',
    );
  });
  for (final failure in ['noPermission', 'network', 'changed']) {
    test('online body $failure: no silent fallback, correct invalidation', () async {
      await db.cacheSharedContent(account.cacheKey, shared, 'cached');
      var calls = 0;
      final api = Api2Client(
        httpClient: MockClient((_) async {
          calls++;
          return failure == 'network'
              ? http.Response('offline', 503)
              : failure == 'noPermission'
              ? http.Response('{"Ok":false,"Msg":"noPermission"}', 200)
              : http.Response(
                  '{"Ok":true,"NoteId":"${shared.note.noteId}","Content":"new","Version":"new","Digest":"new"}',
                  200,
                );
        }),
      );
      final repo = AuthRepository(
        api,
        db,
        MemorySessions(),
        SyncCoordinator(api, db),
      );
      final session = StoredSession(account: account, token: 'test');
      expect(
        (await repo.sharedContent(session, shared, cachedOnly: true)).content,
        'cached',
      );
      expect(calls, 0);
      await expectLater(
        repo.sharedContent(session, shared),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
      expect(
        await repo.sharedNotes(session, cachedOnly: true),
        failure == 'network' ? hasLength(1) : isEmpty,
      );
    });
  }
  test(
    'reset clears shared cache; v3 upgrade preserves personal dirty data',
    () async {
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 8,
      );
      expect(await db.cachedSharedNotes(account.cacheKey), isEmpty);
      final dir = await Directory.systemTemp.createTemp(
        'gemsnote-shared-upgrade-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/cache.sqlite';
      final old = await AppDatabase.open(databasePath: path);
      await old.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 8,
      );
      final draft = await old.createLocalNote(
        account: account,
        notebookId: '',
        isMarkdown: true,
      );
      await old.raw.execute('DROP TABLE shared_notes');
      await old.raw.execute('DROP TABLE note_files');
      await old.raw.setVersion(3);
      await old.raw.close();
      final upgraded = await AppDatabase.open(databasePath: path);
      try {
        expect(
          (await upgraded.dirtyNotes(account.cacheKey)).single.noteId,
          draft.noteId,
        );
        await upgraded.replaceSharedSnapshot(account.cacheKey, [shared]);
        await upgraded.cacheSharedContent(
          account.cacheKey,
          shared,
          'persistent',
        );
      } finally {
        await upgraded.raw.close();
      }
      final reopened = await AppDatabase.open(databasePath: path);
      try {
        expect(
          (await reopened.cachedSharedContent(
            account.cacheKey,
            shared,
          )).content,
          'persistent',
        );
      } finally {
        await reopened.raw.close();
      }
    },
  );
}
