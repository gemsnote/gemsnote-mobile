import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'cached_login_test.dart' show MemorySessions;

import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test'),
    username: 'u',
    email: '',
    logo: '',
  );
  const file = NoteFile(
    id: 'f',
    title: 'photo',
    type: 'png',
    isAttachment: false,
  );
  late AppDatabase db;
  Future<void> seed(AppDatabase target) => target.replaceSnapshot(
    account: account,
    notebooks: [],
    notes: [
      Note.fromJson({'NoteId': 'n', 'UserId': 'u'}),
    ],
    tags: [],
    lastSyncUsn: 1,
  );
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await seed(db);
  });
  tearDown(() => db.raw.close());
  test('clear cache isolates accounts, preserves dirty notes and rejects late downloads', () async {
    final other = Account(
      userId: 'u',
      server: Uri.parse('https://other.test'),
      username: 'u',
      email: '',
      logo: '',
    );
    await db.replaceSnapshot(
      account: other,
      notebooks: [],
      tags: [],
      notes: [
        Note.fromJson({'NoteId': 'n', 'UserId': 'u'}),
      ],
      lastSyncUsn: 9,
    );
    final dirty = await db.createLocalNote(
      account: account,
      notebookId: '',
      isMarkdown: true,
      content: 'unsynced text',
    );
    const empty = NoteFile(
      id: 'empty',
      title: 'empty',
      type: 'bin',
      isAttachment: true,
    );
    const pending = NoteFile(
      id: 'pending',
      title: 'pending',
      type: 'png',
      isAttachment: false,
    );
    await db.replaceNoteFiles(account.cacheKey, 'n', [file, empty, pending]);
    final old = await db.cachedNoteFiles(account.cacheKey, 'n');
    final image = old.singleWhere((f) => f.id == file.id);
    final attachment = old.singleWhere((f) => f.id == empty.id);
    final inFlight = old.singleWhere((f) => f.id == pending.id);
    await db.cacheNoteImage(account.cacheKey, 'n', image, Uint8List(1024));
    await db.cacheNoteAttachment(
      account.cacheKey,
      'n',
      attachment,
      Uint8List(0),
    );
    await db.replaceNoteFiles(other.cacheKey, 'n', [file]);
    final otherFile = (await db.cachedNoteFiles(other.cacheKey, 'n')).single;
    await db.cacheNoteImage(other.cacheKey, 'n', otherFile, Uint8List(10));
    final usage = await db.fileCacheUsage(account.cacheKey);
    expect(usage.files, 2); // Empty cached attachments count as downloaded.
    expect(usage.bytes, 1024);
    await db.clearFileCache(account.cacheKey);
    expect((await db.fileCacheUsage(account.cacheKey)).files, 0);
    expect((await db.fileCacheUsage(account.cacheKey)).bytes, 0);
    expect(await db.cachedNoteFiles(account.cacheKey, 'n'), hasLength(3));
    expect(await db.pendingNoteIds(account.cacheKey), {dirty.noteId});
    expect(
      (await db.dirtyNotes(account.cacheKey)).single.content,
      'unsynced text',
    );
    expect(await db.lastSyncUsn(account.cacheKey), 1);
    expect((await db.fileCacheUsage(other.cacheKey)).bytes, 10);
    expect(
      await db.cachedNoteImage(other.cacheKey, 'n', otherFile),
      hasLength(10),
    );
    for (final stale in [image, inFlight]) {
      await expectLater(
        db.cacheNoteImage(account.cacheKey, 'n', stale, Uint8List(1)),
        throwsStateError,
      );
    }
    await expectLater(
      db.cachedNoteAttachment(account.cacheKey, 'n', attachment),
      throwsStateError,
    );
    final fresh = (await db.cachedNoteFiles(
      account.cacheKey,
      'n',
    )).singleWhere((f) => f.id == file.id);
    await db.cacheNoteImage(account.cacheKey, 'n', fresh, Uint8List(5));
    expect((await db.fileCacheUsage(account.cacheKey)).bytes, 5);
  });
  test('attachment cache isolates account/type, supports empty bytes and rejects stale writes', () async {
    const attach = NoteFile(
      id: 'a',
      title: 'file',
      type: 'bin',
      isAttachment: true,
    );
    await db.replaceNoteFiles(account.cacheKey, 'n', [attach]);
    final current = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
    await db.cacheNoteAttachment(account.cacheKey, 'n', current, Uint8List(0));
    expect(
      await db.cachedNoteAttachment(account.cacheKey, 'n', current),
      isEmpty,
    );
    await expectLater(
      db.cachedNoteAttachment('other', 'n', current),
      throwsStateError,
    );
    await expectLater(
      db.cachedNoteImage(account.cacheKey, 'n', current),
      throwsStateError,
    );
    await expectLater(
      db.cacheNoteImage(
        account.cacheKey,
        'n',
        current,
        Uint8List.fromList([1]),
      ),
      throwsStateError,
    );
    await db.replaceNoteFiles(account.cacheKey, 'n', [attach]);
    await expectLater(
      db.cachedNoteAttachment(account.cacheKey, 'n', current),
      throwsStateError,
    );
    await expectLater(
      db.cacheNoteAttachment(account.cacheKey, 'n', current, Uint8List(0)),
      throwsStateError,
    );
    final fresh = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
    await db.cacheNoteAttachment(
      account.cacheKey,
      'n',
      fresh,
      Uint8List.fromList([5]),
    );
    await seed(db);
    await expectLater(
      db.cachedNoteAttachment(account.cacheKey, 'n', fresh),
      throwsStateError,
    );
  });
  test('images and attachments share the 64 MiB byte budget', () async {
    const a = NoteFile(id: 'a', title: 'a', type: 'bin', isAttachment: true);
    const b = NoteFile(id: 'b', title: 'b', type: 'bin', isAttachment: true);
    await db.replaceNoteFiles(account.cacheKey, 'n', [a, b, file]);
    final files = await db.cachedNoteFiles(account.cacheKey, 'n');
    final first = files.firstWhere((f) => f.id == 'a');
    final second = files.firstWhere((f) => f.id == 'b');
    final image = files.firstWhere((f) => f.id == file.id);
    await db.cacheNoteAttachment(
      account.cacheKey,
      'n',
      first,
      Uint8List(32 * 1024 * 1024),
    );
    await db.cacheNoteAttachment(
      account.cacheKey,
      'n',
      second,
      Uint8List(32 * 1024 * 1024),
    );
    await db.cacheNoteImage(
      account.cacheKey,
      'n',
      image,
      Uint8List.fromList([1]),
    );
    await expectLater(
      db.cachedNoteAttachment(account.cacheKey, 'n', first),
      throwsStateError,
    );
    expect(
      (await db.cachedNoteAttachment(account.cacheKey, 'n', second)).length,
      32 * 1024 * 1024,
    );
    expect((await db.cachedNoteFiles(account.cacheKey, 'n')).length, 3);
  });
  test('repository downloads attachment then reads offline without network; revocation clears cache', () async {
    const id = '507f1f77bcf86cd799439011';
    var offline = false;
    var removed = false;
    var calls = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        calls++;
        if (offline) throw const SocketException('offline');
        if (request.url.path == '/api2/note/getNote') {
          return http.Response(
            jsonEncode({
              'NoteId': 'n',
              'UserId': 'u',
              'Files': removed
                  ? []
                  : [
                      {
                        'FileId': id,
                        'Title': 'file.bin',
                        'Type': 'bin',
                        'IsAttach': true,
                      },
                    ],
            }),
            200,
          );
        }
        expect(request.url.path, '/api2/file/getAttach');
        return http.Response.bytes(
          [1, 2],
          200,
          headers: {'content-disposition': 'attachment; filename="file.bin"'},
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
    final attach = (await repo.noteFiles(session, 'n')).single;
    expect(await repo.noteAttachment(session, 'n', attach), [1, 2]);
    offline = true;
    final previous = calls;
    expect(await repo.noteAttachment(session, 'n', attach, cachedOnly: true), [
      1,
      2,
    ]);
    expect(calls, previous);
    await expectLater(
      repo.noteAttachment(session, 'n', attach),
      throwsA(anything),
    );
    expect(await repo.noteAttachment(session, 'n', attach, cachedOnly: true), [
      1,
      2,
    ]);
    offline = false;
    removed = true;
    await expectLater(
      repo.noteAttachment(session, 'n', attach),
      throwsA(anything),
    );
    await expectLater(
      repo.noteAttachment(session, 'n', attach, cachedOnly: true),
      throwsStateError,
    );
  });
  test('inline download coalesces, checks membership, caches decoded image and rejects external addresses', () async {
    const id = '507f1f77bcf86cd799439011';
    final bytes = File('assets/images/gemsnote_s.png').readAsBytesSync();
    var downloads = 0;
    var calls = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        calls++;
        if (request.url.path == '/api2/note/getNote') {
          return http.Response(
            jsonEncode({
              'NoteId': 'n',
              'UserId': 'u',
              'Files': [
                {
                  'FileId': id,
                  'Title': 'photo',
                  'Type': 'png',
                  'IsAttach': false,
                },
              ],
            }),
            200,
          );
        }
        expect(request.url.path, '/api2/file/getImage');
        downloads++;
        return http.Response.bytes(
          bytes,
          200,
          headers: {'content-type': 'image/png'},
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
    await expectLater(
      repo.downloadInlineImage(
        session,
        'n',
        Uri.parse('https://other.test/image'),
      ),
      throwsStateError,
    );
    expect(calls, 0);
    final uri = Uri.parse('/api2/file/getImage?fileId=$id');
    final result = await Future.wait([
      repo.downloadInlineImage(session, 'n', uri),
      repo.downloadInlineImage(session, 'n', uri),
    ]);
    expect(result.first, bytes);
    expect(downloads, 1);
    expect(await repo.cachedInlineImage(session, 'n', uri), bytes);
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
  });
  test('inline image cache requires current account, note and image membership without network', () async {
    const id = '507f1f77bcf86cd799439011';
    const image = NoteFile(
      id: id,
      title: 'photo',
      type: 'png',
      isAttachment: false,
    );
    await db.replaceNoteFiles(account.cacheKey, 'n', [image]);
    final current = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
    await db.cacheNoteImage(
      account.cacheKey,
      'n',
      current,
      Uint8List.fromList([1]),
    );
    var calls = 0;
    final api = Api2Client(
      httpClient: MockClient((_) async {
        calls++;
        throw StateError('must not request network');
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    final session = StoredSession(account: account, token: 'test');
    final uri = Uri.parse('/api2/file/getImage?fileId=$id');
    expect(await repo.cachedInlineImage(session, 'n', uri), [1]);
    expect(await repo.cachedInlineImage(session, 'other', uri), isNull);
    expect(
      await repo.cachedInlineImage(
        session,
        'n',
        Uri.parse('https://other.test$uri'),
      ),
      isNull,
    );
    await db.replaceNoteFiles(account.cacheKey, 'n', [
      const NoteFile(
        id: id,
        title: 'attachment',
        type: 'png',
        isAttachment: true,
      ),
    ]);
    expect(await repo.cachedInlineImage(session, 'n', uri), isNull);
    expect(calls, 0);
  });
  test('repository offline reads never call network; failures do not silently fall back', () async {
    await db.replaceNoteFiles(account.cacheKey, 'n', [file]);
    final current = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
    await db.cacheNoteImage(
      account.cacheKey,
      'n',
      current,
      Uint8List.fromList([1]),
    );
    var calls = 0;
    var denied = false;
    final api = Api2Client(
      httpClient: MockClient((_) async {
        calls++;
        if (!denied) throw Exception('offline');
        return http.Response('{"Ok":false,"Msg":"noPermission"}', 200);
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    final session = StoredSession(account: account, token: 'test');
    expect(await repo.noteFiles(session, 'n', cachedOnly: true), hasLength(1));
    expect(await repo.noteImage(session, 'n', current, cachedOnly: true), [1]);
    expect(calls, 0);
    await expectLater(repo.noteImage(session, 'n', current), throwsException);
    expect(await repo.noteImage(session, 'n', current, cachedOnly: true), [1]);
    denied = true;
    await expectLater(repo.noteImage(session, 'n', current), throwsException);
    expect(await repo.noteFiles(session, 'n', cachedOnly: true), isEmpty);
    expect(calls, 2);
  });
  test('account/note isolation, logout retention and reset cleanup', () async {
    await db.replaceNoteFiles(account.cacheKey, 'n', [file]);
    final current = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
    await expectLater(
      db.cachedNoteImage(account.cacheKey, 'n', current),
      throwsStateError,
    );
    await db.cacheNoteImage(
      account.cacheKey,
      'n',
      current,
      Uint8List.fromList([1, 2]),
    );
    expect(await db.cachedNoteImage(account.cacheKey, 'n', current), [1, 2]);
    expect(await db.cachedNoteFiles('other', 'n'), isEmpty);
    await expectLater(
      db.cachedNoteImage(account.cacheKey, 'other', current),
      throwsStateError,
    );
    expect(await db.dirtyNotes(account.cacheKey), isEmpty);
    await db.deactivate(account.cacheKey);
    expect(await db.cachedNoteImage(account.cacheKey, 'n', current), [1, 2]);
    await seed(db);
    expect(await db.cachedNoteFiles(account.cacheKey, 'n'), isEmpty);
  });
  test(
    'refresh invalidates bytes and rejects late download even for same file ID',
    () async {
      await db.replaceNoteFiles(account.cacheKey, 'n', [file]);
      final old = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
      await db.cacheNoteImage(
        account.cacheKey,
        'n',
        old,
        Uint8List.fromList([1]),
      );
      await db.replaceNoteFiles(account.cacheKey, 'n', [file]);
      final current = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
      expect(current.cacheGeneration, isNot(old.cacheGeneration));
      await expectLater(
        db.cachedNoteImage(account.cacheKey, 'n', current),
        throwsStateError,
      );
      await expectLater(
        db.cacheNoteImage(account.cacheKey, 'n', old, Uint8List.fromList([2])),
        throwsStateError,
      );
      await db.replaceNoteFiles(account.cacheKey, 'n', []);
      await expectLater(
        db.cacheNoteImage(
          account.cacheKey,
          'n',
          current,
          Uint8List.fromList([2]),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'failed list transaction retains cache, deleting note cascades',
    () async {
      await db.replaceNoteFiles(account.cacheKey, 'n', [file]);
      final current = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
      await db.cacheNoteImage(
        account.cacheKey,
        'n',
        current,
        Uint8List.fromList([1]),
      );
      await expectLater(
        db.replaceNoteFiles(account.cacheKey, 'n', [file, file]),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.cachedNoteImage(account.cacheKey, 'n', current), [1]);
      await db.raw.delete(
        'notes',
        where: 'account_id = ?',
        whereArgs: [account.cacheKey],
      );
      expect(await db.cachedNoteFiles(account.cacheKey, 'n'), isEmpty);
    },
  );
  test(
    '64 MiB budget evicts oldest image bytes but retains file entries',
    () async {
      final files = List.generate(
        9,
        (i) =>
            NoteFile(id: '$i', title: '$i', type: 'png', isAttachment: false),
      );
      await db.replaceNoteFiles(account.cacheKey, 'n', files);
      final current = await db.cachedNoteFiles(account.cacheKey, 'n');
      final bytes = Uint8List(8 * 1024 * 1024);
      for (final item in current) {
        await db.cacheNoteImage(account.cacheKey, 'n', item, bytes);
      }
      await expectLater(
        db.cachedNoteImage(account.cacheKey, 'n', current.first),
        throwsStateError,
      );
      expect(
        (await db.cachedNoteImage(account.cacheKey, 'n', current.last)).length,
        bytes.length,
      );
      expect(await db.cachedNoteFiles(account.cacheKey, 'n'), hasLength(9));
    },
  );
  test('v4 upgrade preserves notes and stores cache across reopen', () async {
    final dir = await Directory.systemTemp.createTemp('gemsnote-file-cache-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/db.sqlite';
    final old = await AppDatabase.open(databasePath: path);
    await seed(old);
    await old.raw.execute('DROP TABLE note_files');
    await old.raw.setVersion(4);
    await old.raw.close();
    final migrated = await AppDatabase.open(databasePath: path);
    expect(await migrated.notes(account.cacheKey), hasLength(1));
    await migrated.replaceNoteFiles(account.cacheKey, 'n', [file]);
    final current = (await migrated.cachedNoteFiles(
      account.cacheKey,
      'n',
    )).single;
    await migrated.cacheNoteImage(
      account.cacheKey,
      'n',
      current,
      Uint8List.fromList([1]),
    );
    await migrated.raw.close();
    final reopened = await AppDatabase.open(databasePath: path);
    try {
      expect(await reopened.cachedNoteImage(account.cacheKey, 'n', current), [
        1,
      ]);
    } finally {
      await reopened.raw.close();
    }
  });
}
