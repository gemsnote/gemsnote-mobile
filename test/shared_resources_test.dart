import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/shared_file_cache.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/shared_note.dart';
import 'package:gemsnote/domain/models/shared_file.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/shared_files_page.dart';
import 'package:gemsnote/services/attachment_exporter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

class SharedResourceRepository implements AuthRepository {
  var downloads = 0;
  var reads = 0;
  bool fail = true;
  @override
  Future<Uint8List?> cachedSharedFile(
    StoredSession session,
    SharedNote note,
    SharedFile file,
  ) async {
    reads++;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List> downloadSharedFile(
    StoredSession session,
    SharedNote note,
    SharedFile file,
  ) async {
    downloads++;
    if (fail) throw StateError('offline');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const noteId = '0123456789abcdef01234567';
  const fileId = '0123456789abcdef01234568';
  const ownerId = '0123456789abcdef01234569';
  const content = 'shared content';
  final version = sha256.convert(utf8.encode(content)).toString();
  final png = File('assets/images/gemsnote_s.png').readAsBytesSync();
  final server = Uri.parse('https://example.test/');
  final account = Account(
    userId: 'u',
    server: server,
    username: '',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 'token');
  SharedFile resource(Uint8List bytes, {String kind = 'image'}) => SharedFile(
    noteId: noteId,
    fileId: fileId,
    kind: kind,
    title: 'file.png',
    size: bytes.length,
    version: sha256.convert(bytes).toString(),
  );
  SharedNote snapshot(SharedFile file) => SharedNote.fromJson({
    'NoteId': noteId,
    'OwnerUserId': ownerId,
    'Title': 'Shared',
    'Version': version,
    'IsMarkdown': true,
    'Files': [file.toJson()],
  });
  http.Response bodyResponse() => http.Response(
    jsonEncode({
      'Ok': true,
      'NoteId': noteId,
      'Version': version,
      'Digest': version,
      'Content': content,
    }),
    200,
  );
  for (final mode in [
    'image',
    'attachment',
    'json-attachment',
    'hash-mismatch',
    'size-mismatch',
    'header-mismatch',
    'redirect',
    'denied-before',
    'denied-file',
    'denied-after',
  ]) {
    test(
      'shared resource validates snapshot, digest and permission: $mode',
      () async {
        final bytes = mode == 'json-attachment'
            ? Uint8List.fromList(utf8.encode('{"Ok":false,"Msg":"example"}'))
            : png;
        final file = resource(
          bytes,
          kind: mode.contains('attachment') ? 'attachment' : 'image',
        );
        final shared = snapshot(file);
        var bodyCalls = 0;
        var fileCalls = 0;
        final api = Api2Client(
          httpClient: MockClient((request) async {
            expect(request.followRedirects, isFalse);
            expect(request.headers.values, contains('Bearer token'));
            if (request.url.path.endsWith('/content')) {
              bodyCalls++;
              if (mode == 'denied-before' ||
                  (mode == 'denied-after' && bodyCalls == 2)) {
                return http.Response('{"Ok":false,"Msg":"noPermission"}', 200);
              }
              return bodyResponse();
            }
            fileCalls++;
            expect(
              request.url.path,
              '/api2/shared/notes/$noteId/files/$fileId',
            );
            if (mode == 'denied-file') {
              return http.Response(
                '{"Ok":false,"Msg":"noPermission"}',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (mode == 'redirect') {
              return http.Response(
                '',
                302,
                headers: {'location': 'https://evil.test'},
              );
            }
            final payload = mode == 'size-mismatch'
                ? bytes.sublist(1)
                : mode == 'hash-mismatch'
                ? Uint8List(bytes.length)
                : bytes;
            return http.Response.bytes(
              payload,
              200,
              headers: {
                'x-gemsnote-sha256': mode == 'header-mismatch'
                    ? '0' * 64
                    : file.version,
                'content-type': file.isAttachment
                    ? 'application/json'
                    : 'image/png',
              },
            );
          }),
        );
        final operation = api.sharedFile(
          server: server,
          token: 'token',
          shared: shared,
          file: file,
        );
        if (['image', 'attachment', 'json-attachment'].contains(mode)) {
          expect(await operation, bytes);
          expect(bodyCalls, 2);
          expect(fileCalls, 1);
        } else {
          await expectLater(operation, throwsA(isA<ApiException>()));
          expect(fileCalls, mode == 'denied-before' ? 0 : 1);
        }
      },
    );
  }

  late AppDatabase db;
  late SharedFileCache cache;
  final file = resource(png);
  final shared = snapshot(file);
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    cache = SharedFileCache(db.raw, account.cacheKey);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [],
      tags: [],
      lastSyncUsn: 1,
    );
    await db.replaceSharedSnapshot(account.cacheKey, [shared]);
    await db.cacheSharedContent(account.cacheKey, shared, content);
  });
  tearDown(() => db.raw.close());

  test('shared cache survives identical snapshots and cannot refill after clearing or revocation', () async {
    final generation = await cache.begin(shared, file);
    await cache.complete(shared, file, generation, png);
    expect((await db.fileCacheUsage(account.cacheKey)).bytes, png.length);
    expect(
      (await db.cachedSharedNotes(account.cacheKey))
          .single
          .files
          .single
          .version,
      file.version,
    );
    await db.replaceSharedSnapshot(account.cacheKey, [shared]);
    expect(await cache.read(shared, file), png);
    await expectLater(
      cache.complete(shared, file, generation, png),
      throwsStateError,
    );
    final second = await cache.begin(shared, file);
    await db.clearFileCache(account.cacheKey);
    expect(await cache.read(shared, file), isNull);
    await expectLater(
      cache.complete(shared, file, second, png),
      throwsStateError,
    );
    await expectLater(
      SharedFileCache(db.raw, 'other').read(shared, file),
      throwsStateError,
    );
    final third = await cache.begin(shared, file);
    await db.replaceSharedSnapshot(account.cacheKey, []);
    await expectLater(
      cache.complete(shared, file, third, png),
      throwsStateError,
    );
    expect(await db.raw.query('shared_files'), isEmpty);
  });

  test(
    'shared resource bytes participate in the global cache eviction budget',
    () async {
      final bytes = Uint8List(8 * 1024 * 1024);
      final hash = sha256.convert(bytes).toString();
      final files = [
        for (var i = 0; i < 9; i++)
          SharedFile(
            noteId: noteId,
            fileId: i.toRadixString(16).padLeft(24, '0'),
            kind: 'image',
            title: '$i',
            size: bytes.length,
            version: hash,
          ),
      ];
      final many = SharedNote(
        note: shared.note,
        version: version,
        files: files,
      );
      await db.replaceSharedSnapshot(account.cacheKey, [many]);
      for (final file in files) {
        await cache.complete(many, file, await cache.begin(many, file), bytes);
      }
      expect(
        (await db.fileCacheUsage(account.cacheKey)).bytes,
        64 * 1024 * 1024,
      );
      expect(await cache.read(many, files.first), isNull);
      expect(await cache.read(many, files.last), hasLength(bytes.length));
    },
  );

  test('invalid file snapshot rolls back parent edits and resource cache atomically', () async {
    final generation = await cache.begin(shared, file);
    await cache.complete(shared, file, generation, png);
    final invalid = SharedNote(
      note: shared.note.copyWith(title: 'Changed'),
      version: shared.version,
      files: [file, file],
    );
    await expectLater(
      db.replaceSharedSnapshot(account.cacheKey, [invalid]),
      throwsStateError,
    );
    expect(
      (await db.cachedSharedNotes(account.cacheKey)).single.note.title,
      'Shared',
    );
    expect(await cache.read(shared, file), png);
    expect(
      (await db.cachedSharedContent(account.cacheKey, shared)).content,
      content,
    );
  });

  test('permission denial clears cached body and resources without offline fallback', () async {
    final generation = await cache.begin(shared, file);
    await cache.complete(shared, file, generation, png);
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response('{"Ok":false,"Msg":"noPermission"}', 200),
      ),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    await expectLater(
      repo.downloadSharedFile(session, shared, file),
      throwsA(isA<ApiException>()),
    );
    expect(await db.cachedSharedNotes(account.cacheKey), isEmpty);
    expect(await db.raw.query('shared_files'), isEmpty);
    expect((await db.fileCacheUsage(account.cacheKey)).bytes, 0);
  });

  test('concurrent resource downloads deduplicate; cleared cache rejects a late completion', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var downloads = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/content')) return bodyResponse();
        downloads++;
        started.complete();
        return response.future;
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    final first = repo.downloadSharedFile(session, shared, file);
    final second = repo.downloadSharedFile(session, shared, file);
    final failed = expectLater(first, throwsStateError);
    final alsoFailed = expectLater(second, throwsStateError);
    await started.future;
    await db.clearFileCache(account.cacheKey);
    response.complete(
      http.Response.bytes(
        png,
        200,
        headers: {
          'content-type': 'image/png',
          'x-gemsnote-sha256': file.version,
        },
      ),
    );
    await failed;
    await alsoFailed;
    expect(downloads, 1);
    expect(await cache.read(shared, file), isNull);
  });

  test(
    'v15 upgrade preserves shared body and supports persistent resource cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shared-cache-upgrade-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/notes.db';
      var disk = await AppDatabase.open(databasePath: path);
      await disk.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 1,
      );
      await disk.replaceSharedSnapshot(account.cacheKey, [shared]);
      await disk.cacheSharedContent(account.cacheKey, shared, content);
      await disk.raw.execute('DROP TABLE shared_files');
      await disk.raw.setVersion(15);
      await disk.raw.close();
      disk = await AppDatabase.open(databasePath: path);
      expect(
        (await disk.cachedSharedContent(account.cacheKey, shared)).content,
        content,
      );
      await disk.replaceSharedSnapshot(account.cacheKey, [shared]);
      var diskCache = SharedFileCache(disk.raw, account.cacheKey);
      await diskCache.complete(
        shared,
        file,
        await diskCache.begin(shared, file),
        png,
      );
      await disk.raw.close();
      disk = await AppDatabase.open(databasePath: path);
      diskCache = SharedFileCache(disk.raw, account.cacheKey);
      expect(await diskCache.read(shared, file), png);
      await disk.raw.close();
    },
  );

  for (final offline in [false, true]) {
    testWidgets(
      'shared attachment save is explicit, read-only and honors offline mode: $offline',
      (tester) async {
        final repo = SharedResourceRepository();
        Uint8List? saved;
        final attachment = resource(
          Uint8List.fromList([1, 2, 3]),
          kind: 'attachment',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: SharedFilesPage(
              repository: repo,
              session: session,
              note: snapshot(attachment),
              cachedOnly: offline,
              attachmentExporter: AttachmentExporter(
                save:
                    ({
                      required fileName,
                      required bytes,
                      required mimeType,
                    }) async {
                      saved = bytes;
                      return Uri.parse('content://saved/file');
                    },
              ),
            ),
          ),
        );
        expect(repo.downloads, 0);
        expect(repo.reads, 0);
        await tester.tap(find.byTooltip('文件操作'));
        await tester.pumpAndSettle();
        expect(find.text('上传附件'), findsNothing);
        expect(find.text('下载到缓存'), offline ? findsNothing : findsOneWidget);
        await tester.tap(find.text('保存到文件'));
        await tester.pumpAndSettle();
        if (!offline) {
          expect(find.textContaining('读取共享文件失败'), findsOneWidget);
          expect(saved, isNull);
          repo.fail = false;
          await tester.tap(find.byTooltip('文件操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存到文件'));
          await tester.pumpAndSettle();
        }
        expect(saved, [1, 2, 3]);
        expect(repo.downloads, offline ? 0 : 2);
        expect(repo.reads, offline ? 1 : 0);
      },
    );
  }
}
