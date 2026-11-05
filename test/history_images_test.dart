import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/history_image_cache.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/body_image_references.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/domain/models/note_history.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/cached_login_test.dart' show MemorySessions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = '0123456789abcdef01234567';
  final server = Uri.parse('https://example.test/');
  final uri = Uri.parse('/file/outputImage?fileId=$id');
  final body = '![photo]($uri)';
  final account = Account(
    userId: 'u',
    server: server,
    username: '',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 'token');
  const history = NoteHistory(
    id: 'h',
    updatedTime: '2026-01-01',
    updatedUserId: 'u',
  );
  final png = File('assets/images/gemsnote_s.png').readAsBytesSync();
  late AppDatabase db;
  late HistoryImageCache cache;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    cache = HistoryImageCache(db.raw, account.cacheKey);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      tags: [],
      lastSyncUsn: 2,
      notes: [
        Note.fromJson({
          'NoteId': 'n',
          'Content': 'current',
          'Usn': 2,
          'IsMarkdown': true,
        }),
      ],
    );
    await db.cacheHistories(account.cacheKey, 'n', [history]);
    await db.cacheHistoryContent(account.cacheKey, 'n', 'h', body);
  });
  tearDown(() => db.raw.close());

  test('body references exclude code, links, external URLs and foreign origins', () {
    expect(
      bodyImageIds(
        '```\n$body\n```\n`$body`\n[link]($uri)',
        isMarkdown: true,
        server: server,
      ),
      isEmpty,
    );
    expect(
      bodyImageIds(
        '$body\n![external](https://evil.test$uri)\n![fake](/api2/file/getImage?fileId=bad)',
        isMarkdown: true,
        server: server,
      ),
      {id},
    );
    expect(
      bodyImageIds(
        '<img src="$uri"><a href="$uri">link</a>',
        isMarkdown: false,
        server: server,
      ),
      {id},
    );
  });

  test(
    'historical images use only API2 and require the exact owned history body',
    () async {
      var remoteBody = body;
      var denied = false;
      var downloads = 0;
      final api = Api2Client(
        httpClient: MockClient((request) async {
          expect(request.url.origin, server.origin);
          expect(request.headers.values, contains('Bearer token'));
          expect(request.followRedirects, isFalse);
          if (request.url.path == '/api2/note/getHistoryContent') {
            expect(request.url.queryParameters['historyId'], 'h');
            return http.Response(
              jsonEncode(
                denied
                    ? {'Ok': false, 'Msg': 'noteNotExists'}
                    : {
                        'Ok': true,
                        'Item': {'HistoryId': 'h', 'Content': remoteBody},
                      },
              ),
              200,
            );
          }
          expect(request.url.path, '/api2/file/getImage');
          expect(request.url.queryParameters['fileId'], id);
          downloads++;
          return http.Response.bytes(
            png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      Future<Uint8List> load() => api.historyImage(
        server: server,
        token: 'token',
        noteId: 'n',
        historyId: 'h',
        fileId: id,
        expectedContent: body,
        isMarkdown: true,
      );
      expect(await load(), png);
      remoteBody = 'changed';
      await expectLater(load(), throwsA(isA<ApiException>()));
      remoteBody = body;
      denied = true;
      await expectLater(load(), throwsA(isA<ApiException>()));
      expect(downloads, 1);
    },
  );

  test('cache refresh preserves unchanged history; clear and replacement reject late writes', () async {
    final generation = await cache.begin('n', 'h', id, body);
    await cache.complete('n', 'h', id, body, generation, png);
    await db.cacheHistories(account.cacheKey, 'n', [history]);
    expect(await cache.read('n', 'h', id, body), png);
    expect((await db.fileCacheUsage(account.cacheKey)).bytes, png.length);
    expect((await db.fileCacheUsage('other')).bytes, 0);
    await expectLater(
      HistoryImageCache(db.raw, 'other').read('n', 'h', id, body),
      throwsStateError,
    );
    await db.clearFileCache(account.cacheKey);
    expect(await cache.read('n', 'h', id, body), isNull);
    await expectLater(
      cache.complete('n', 'h', id, body, generation, png),
      throwsStateError,
    );
    final second = await cache.begin('n', 'h', id, body);
    await db.cacheHistoryContent(account.cacheKey, 'n', 'h', 'changed');
    await expectLater(
      cache.complete('n', 'h', id, body, second, png),
      throwsStateError,
    );
    await db.cacheHistoryContent(account.cacheKey, 'n', 'h', body);
    await expectLater(
      cache.complete('n', 'h', id, body, second, png),
      throwsStateError,
    );
    final third = await cache.begin('n', 'h', id, body);
    await db.cacheHistories(account.cacheKey, 'n', []);
    await expectLater(
      cache.complete('n', 'h', id, body, third, png),
      throwsStateError,
    );
    expect(await db.raw.query('history_images'), isEmpty);
  });

  test(
    'current and historical resources share the global 64 MiB cache budget',
    () async {
      await db.replaceNoteFiles(account.cacheKey, 'n', [
        const NoteFile(
          id: 'attachment',
          title: 'a',
          type: 'bin',
          isAttachment: true,
        ),
      ]);
      final file = (await db.cachedNoteFiles(account.cacheKey, 'n')).single;
      await db.cacheNoteAttachment(
        account.cacheKey,
        'n',
        file,
        Uint8List(32 * 1024 * 1024),
      );
      final bytes = Uint8List(8 * 1024 * 1024);
      for (var i = 0; i < 8; i++) {
        final generation = await cache.begin('n', 'h', '$i', body);
        await cache.complete('n', 'h', '$i', body, generation, bytes);
      }
      expect(
        (await db.fileCacheUsage(account.cacheKey)).bytes,
        64 * 1024 * 1024,
      );
      await expectLater(
        db.cachedNoteAttachment(account.cacheKey, 'n', file),
        throwsStateError,
      );
      expect(await cache.read('n', 'h', '7', body), hasLength(bytes.length));
      await db.clearFileCache(account.cacheKey);
      expect((await db.fileCacheUsage(account.cacheKey)).bytes, 0);
    },
  );

  test('repository caches, deduplicates and displays restored historical images offline', () async {
    final response = Completer<http.Response>();
    var calls = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        calls++;
        if (request.url.path == '/api2/note/getHistoryContent') {
          return http.Response(
            jsonEncode({
              'Ok': true,
              'Item': {'HistoryId': 'h', 'Content': body},
            }),
            200,
          );
        }
        expect(request.url.path, '/api2/file/getImage');
        return response.future;
      }),
    );
    final repo = AuthRepository(
      api,
      db,
      MemorySessions(),
      SyncCoordinator(api, db),
    );
    final first = repo.downloadHistoryImage(session, 'n', 'h', body, true, uri);
    final second = repo.downloadHistoryImage(
      session,
      'n',
      'h',
      body,
      true,
      uri,
    );
    response.complete(
      http.Response.bytes(png, 200, headers: {'content-type': 'image/png'}),
    );
    expect(await first, png);
    expect(await second, png);
    expect(calls, 2);
    expect(
      await repo.cachedHistoryImage(session, 'n', 'h', body, true, uri),
      png,
    );
    expect(
      await repo.cachedHistoryImage(
        session,
        'n',
        'h',
        body,
        true,
        Uri.parse('https://evil.test$uri'),
      ),
      isNull,
    );
    await repo.restoreHistory(session, 'n', 'h', cachedOnly: true);
    expect((await db.dirtyNotes(account.cacheKey)).single.content, body);
    expect(await repo.cachedInlineImage(session, 'n', uri), png);
    expect(calls, 2);
    await db.raw.update('notes', {'local_is_deleted': 1});
    await expectLater(
      repo.cachedHistoryImage(session, 'n', 'h', body, true, uri),
      throwsStateError,
    );
    expect(await cache.restoredImage('n', id), isNull);
  });

  test(
    'v14 upgrade adds history image cache and preserves offline contents',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'history-image-upgrade-',
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
      await disk.raw.execute('DROP TABLE history_images');
      await disk.raw.setVersion(14);
      await disk.raw.close();
      disk = await AppDatabase.open(databasePath: path);
      expect(await disk.raw.getVersion(), AppDatabase.schemaVersion);
      expect(await disk.raw.query('history_images'), isEmpty);
      expect(await disk.lastSyncUsn(account.cacheKey), 1);
      await disk.raw.close();
    },
  );
}
