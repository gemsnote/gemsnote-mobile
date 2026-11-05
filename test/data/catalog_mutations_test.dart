import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

void main() {
  late AppDatabase db;
  late AuthRepository repo;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 'token');
  const bookId = '507f1f77bcf86cd799439011';
  late Map<String, Object?> book;
  late List<Map<String, Object?>> notes;
  late List<Map<String, Object?>> tags;
  var usn = 5, writes = 0;
  var loseDeleteResponse = false, failUpdate = false;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    usn = 5;
    writes = 0;
    loseDeleteResponse = false;
    failUpdate = false;
    book = {'NotebookId': bookId, 'Title': 'Empty', 'Usn': 1};
    notes = [];
    tags = [
      {'Tag': 'old', 'UserId': 'u', 'Usn': 2},
    ];
    await db.replaceSnapshot(
      account: account,
      notebooks: [Notebook.fromJson(book)],
      notes: [],
      tags: tags,
      lastSyncUsn: 5,
    );
    final api = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.url.path, startsWith('/api2/'));
        expect(request.headers.values, contains('Bearer token'));
        Object? result;
        final route = request.url.path.split('/').last;
        if (request.method == 'POST') {
          writes++;
          final fields = request.bodyFields;
          if (route == 'delete') {
            expect(fields, {'notebookId': bookId, 'usn': '1'});
            book = {...book, 'IsDeleted': true, 'Usn': ++usn};
            if (loseDeleteResponse) throw http.ClientException('response lost');
            result = {'Ok': true};
          } else if (route == 'addTag') {
            tags.add({
              'Tag': fields['tag'],
              'IsDeleted': false,
              'UserId': 'u',
              'Usn': ++usn,
            });
            result = tags.last;
          } else if (route == 'deleteTag') {
            expect(fields['tag'], 'old');
            expect(fields['usn'], '2');
            tags[0] = {...tags[0], 'IsDeleted': true, 'Usn': ++usn};
            for (var i = 0; i < notes.length; i++) {
              notes[i] = {
                ...notes[i],
                'Tags': (notes[i]['Tags'] as List)
                    .where((tag) => tag != 'old')
                    .toList(),
                'Usn': ++usn,
              };
            }
            result = {'Ok': true, 'Usn': usn};
          } else if (route == 'update') {
            if (failUpdate) return http.Response('unavailable', 503);
            final i = notes.indexWhere((n) => n['NoteId'] == fields['NoteId']);
            final index = i < 0
                ? notes.indexWhere((n) => n['NoteId'] == fields['noteId'])
                : i;
            notes[index] = {
              ...notes[index],
              'Tags': [
                for (var t = 0; fields.containsKey('Tags[$t]'); t++)
                  fields['Tags[$t]'],
              ],
              'Usn': ++usn,
            };
            result = notes[index];
          } else {
            throw StateError('Unexpected POST $route');
          }
        } else if (route == 'getSyncState') {
          result = {'LastSyncUsn': usn};
        } else if (route == 'getNote') {
          result = {
            ...notes.firstWhere(
              (n) => n['NoteId'] == request.url.queryParameters['noteId'],
            ),
            'Files': [],
          };
        } else {
          final after = int.parse(
            request.url.queryParameters['afterUsn'] ?? '0',
          );
          result = (switch (route) {
            'getSyncNotebooks' => [book],
            'getSyncNotesWithContent' => notes,
            'getSyncTags' => tags,
            _ => throw StateError('Unexpected GET $route'),
          }).where((row) => (row['Usn'] as int) > after).toList();
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    repo = AuthRepository(api, db, MemorySessions(), SyncCoordinator(api, db));
  });
  tearDown(() => db.raw.close());

  Future<void> seedNotes() async {
    notes = [
      for (var i = 0; i < 2; i++)
        {
          'NoteId': '507f1f77bcf86cd79943901${i + 2}',
          'UserId': 'u',
          'NotebookId': bookId,
          'Content': 'body',
          'Title': 'title',
          'Usn': i + 3,
          'Tags': ['old', 'other'],
          'IsTrash': i == 1,
          'IsMarkdown': true,
          'IsStar': false,
        },
    ];
    await db.replaceSnapshot(
      account: account,
      notebooks: [Notebook.fromJson(book)],
      notes: notes.map(Note.fromJson).toList(),
      tags: tags,
      lastSyncUsn: 5,
    );
  }

  test('delete empty notebook consumes tombstone through sync', () async {
    await repo.deleteNotebook(session, Notebook.fromJson(book));
    expect(await db.notebooks(account.cacheKey), isEmpty);
    expect(await db.lastSyncUsn(account.cacheKey), 6);
  });
  test(
    'lost notebook delete response preserves cache until next sync',
    () async {
      loseDeleteResponse = true;
      await expectLater(
        repo.deleteNotebook(session, Notebook.fromJson(book)),
        throwsException,
      );
      expect(await db.notebooks(account.cacheKey), hasLength(1));
      await repo.synchronize(session);
      expect(await db.notebooks(account.cacheKey), isEmpty);
      expect(writes, 1);
    },
  );
  test('nonempty and locally changed notebooks cannot be deleted', () async {
    await seedNotes();
    await expectLater(
      repo.deleteNotebook(session, Notebook.fromJson(book)),
      throwsStateError,
    );
    expect(writes, 0);
    await db.editLocalNotebook(account.cacheKey, bookId, title: 'pending');
    await expectLater(
      repo.deleteNotebook(session, Notebook.fromJson(book)),
      throwsStateError,
    );
    expect(writes, 0);
  });
  test('global tag deletion synchronizes active and trashed notes', () async {
    await seedNotes();
    await repo.deleteTag(session, 'old');
    expect(await db.hasTagReferences(account.cacheKey, 'old'), isFalse);
    expect(
      (await db.tagCounts(
        account.cacheKey,
        includeUnused: true,
      )).containsKey('old'),
      isFalse,
    );
  });
  test('tag deletion refuses pending local changes', () async {
    await seedNotes();
    await db.saveLocalNote(
      account.cacheKey,
      (await db.notes(account.cacheKey)).first,
    );
    await expectLater(repo.deleteTag(session, 'old'), throwsStateError);
    expect(writes, 0);
  });
  test(
    'rename migrates active and trash references before removing old catalog',
    () async {
      await seedNotes();
      await repo.renameTag(session, 'old', 'new');
      expect(await db.hasTagReferences(account.cacheKey, 'old'), isFalse);
      expect(await db.hasTagReferences(account.cacheKey, 'new'), isTrue);
      expect(notes.every((n) => (n['Tags'] as List).contains('new')), isTrue);
      expect(await db.dirtyNotes(account.cacheKey), isEmpty);
      expect(tags.first['IsDeleted'], isTrue);
    },
  );
  test(
    'failed rename retains queued replacements and old catalog for retry',
    () async {
      await seedNotes();
      failUpdate = true;
      await expectLater(repo.renameTag(session, 'old', 'new'), throwsException);
      expect(await db.dirtyNotes(account.cacheKey), hasLength(2));
      expect(tags.first['IsDeleted'], isNot(true));
      failUpdate = false;
      await repo.renameTag(session, 'old', 'new');
      expect(await db.dirtyNotes(account.cacheKey), isEmpty);
      expect(tags.first['IsDeleted'], isTrue);
    },
  );
}
