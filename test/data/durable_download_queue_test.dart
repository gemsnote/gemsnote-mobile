import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/file_download_journal.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/services/account_file_cache.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late AppDatabase db;
  late FileDownloadJournal journal;
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://example.test/'),
    username: 'u',
    email: '',
    logo: '',
  );
  Note note({int usn = 3, bool trash = false}) => Note.fromJson({
    'NoteId': 'n',
    'UserId': 'u',
    'Title': 'Note',
    'Usn': usn,
    'IsTrash': trash,
  });
  NoteFile file(int index) => NoteFile(
    id: index.toRadixString(16).padLeft(24, '0'),
    title: '$index',
    type: 'txt',
    isAttachment: true,
  );
  Future<List<NoteFile>> list(int count) async {
    await db.replaceNoteFiles(
      account.cacheKey,
      'n',
      List.generate(count, file),
    );
    return db.cachedNoteFiles(account.cacheKey, 'n');
  }

  Future<void> download(String id, NoteFile item) => db.cacheNoteAttachment(
    account.cacheKey,
    id,
    item,
    Uint8List.fromList([1, 2, 3]),
  );
  Future<void> reopen() async {
    await db.raw.close();
    db = await AppDatabase.open(databasePath: databasePath);
    journal = FileDownloadJournal(db.raw, account.cacheKey);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'gemsnote-download-test-',
    );
    databasePath = '${directory.path}/notes.sqlite';
    db = await AppDatabase.open(databasePath: databasePath);
    await db.replaceSnapshot(
      account: account,
      notebooks: [],
      notes: [note()],
      tags: [],
      lastSyncUsn: 3,
    );
    journal = FileDownloadJournal(db.raw, account.cacheKey);
  });
  tearDown(() async {
    await db.raw.close();
    await directory.delete(recursive: true);
  });

  test('restart retries failed files only, preserves successful bytes and sync cursor', () async {
    var lists = 0;
    final transfers = <String>[];
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) {
        lists++;
        return list(3);
      },
      download: (id, item) async {
        transfers.add(item.title);
        if (item.title == '1') throw StateError('offline');
        await download(id, item);
      },
      onProgress: (_, _, _) {},
    );
    expect(transfers, containsAll(['0', '1', '2']));
    expect((await journal.status()).files, 1);
    expect((await journal.status()).failed, 1);
    await reopen();
    transfers.clear();
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) async => throw StateError('must reuse listing'),
      download: (id, item) async {
        transfers.add(item.title);
        await download(id, item);
      },
      onProgress: (_, _, _) {},
    );
    expect(lists, 1);
    expect(transfers, ['1']);
    expect((await journal.status()).isEmpty, isTrue);
    expect((await db.fileCacheUsage(account.cacheKey)).files, 3);
    expect(await db.lastSyncUsn(account.cacheKey), 3);
  });

  test(
    'only one cache runner owns an account across concurrent queues',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final first = AccountFileCache(journal: journal).run(
        ['n'],
        listFiles: (_) => list(1),
        download: (id, item) async {
          started.complete();
          await release.future;
          await download(id, item);
        },
        onProgress: (_, _, _) {},
      );
      await started.future;
      var duplicateLists = 0;
      await expectLater(
        AccountFileCache(journal: FileDownloadJournal(db.raw, account.cacheKey))
            .run(
              ['n'],
              listFiles: (_) async {
                duplicateLists++;
                return [];
              },
              download: (_, _) async {},
              onProgress: (_, _, _) {},
            ),
        throwsStateError,
      );
      expect(duplicateLists, 0);
      release.complete();
      await first;
      await AccountFileCache(journal: journal).run(
        ['n'],
        listFiles: (_) async => throw StateError('reuses listing'),
        download: (_, _) async => throw StateError('already cached'),
        onProgress: (_, _, _) {},
      );
      expect((await journal.status()).isEmpty, true);
    },
  );

  test('expired runner lease can recover after process interruption', () async {
    final first = await journal.claimRun();
    expect(first, isNotNull);
    await reopen();
    expect(await journal.claimRun(), isNull);
    await db.raw.update(
      'app_preferences',
      {'value': '$first:0'},
      where: 'name = ?',
      whereArgs: ['cache_download_lease:${account.cacheKey}'],
    );
    final second = await journal.claimRun();
    expect(second, isNotNull);
    expect(second, isNot(first));
    await journal.releaseRun(first!);
    expect(await journal.claimRun(), isNull);
    await journal.releaseRun(second!);
    expect(await journal.claimRun(), isNotNull);
  });

  test('pause drains active transfers and restart continues only unscheduled files', () async {
    final queue = AccountFileCache(journal: journal);
    final started = Completer<void>();
    final gate = Completer<void>();
    var transfers = 0;
    final run = queue.run(
      ['n'],
      listFiles: (_) => list(7),
      download: (id, item) async {
        if (++transfers == 3) started.complete();
        await gate.future;
        await download(id, item);
      },
      onProgress: (_, _, _) {},
    );
    await started.future;
    queue.cancel();
    gate.complete();
    await run;
    expect(transfers, 3);
    expect((await journal.status()).files, 4);
    await reopen();
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) async => throw StateError('listing already saved'),
      download: (id, item) async {
        transfers++;
        await download(id, item);
      },
      onProgress: (_, _, _) {},
    );
    expect(transfers, 7);
    expect((await journal.status()).isEmpty, isTrue);
  });

  test('bytes committed before interrupted acknowledgement are reused after restart', () async {
    final job = (await journal.plan(['n'])).single;
    final files = await list(1);
    await journal.saveList(job, files);
    await download('n', files.single);
    await reopen();
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) async => throw StateError('unexpected list'),
      download: (_, _) async => throw StateError('must reuse durable bytes'),
      onProgress: (_, _, errors) => expect(errors, 0),
    );
    expect((await journal.status()).isEmpty, isTrue);
  });

  test('listing failure persists and retries once per pass', () async {
    var lists = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      await AccountFileCache(journal: journal).run(
        ['n'],
        listFiles: (_) async {
          lists++;
          throw StateError('offline');
        },
        download: download,
        onProgress: (_, _, errors) => expect(errors, 1),
      );
      await reopen();
      final status = await journal.status();
      expect(status.notes, 1);
      expect(status.failed, 1);
    }
    expect(lists, 2);
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) => list(0),
      download: download,
      onProgress: (_, _, _) {},
    );
    expect((await journal.status()).isEmpty, isTrue);
  });

  test('new file snapshot forces replanning and rejects stale acknowledgements after clear', () async {
    final job = (await journal.plan(['n'])).single;
    final old = await list(1);
    await journal.saveList(job, old);
    await list(2);
    expect(await journal.entries(job), isNull);
    final fresh = await db.cachedNoteFiles(account.cacheKey, 'n');
    await journal.saveList(job, fresh);
    await expectLater(
      journal.finishFile(job, old.single, success: true),
      throwsStateError,
    );
    await db.clearFileCache(account.cacheKey);
    expect((await journal.status()).isEmpty, isTrue);
    await expectLater(journal.saveList(job, fresh), throwsStateError);
    await expectLater(
      journal.finishFile(job, fresh.first, success: true),
      throwsStateError,
    );
    expect(await db.raw.query('cache_download_jobs'), isEmpty);
  });

  test(
    'changed note USN creates a new job; trashed notes never download',
    () async {
      final old = (await journal.plan(['n'])).single;
      await db.mergeChanges(
        account: account,
        notebooks: [],
        notes: [note(usn: 4)],
        tags: [],
        lastSyncUsn: 4,
      );
      final fresh = (await journal.plan(['n'])).single;
      expect(fresh.id, isNot(old.id));
      await expectLater(journal.saveList(old, []), throwsStateError);
      await db.saveLocalNote(account.cacheKey, note(usn: 4, trash: true));
      await AccountFileCache(journal: journal).run(
        ['n'],
        listFiles: (_) async => throw StateError('must not read trash'),
        download: (_, _) async => throw StateError('must not download trash'),
        onProgress: (_, _, _) {},
      );
      expect(await db.raw.query('cache_download_jobs'), isEmpty);
    },
  );

  test(
    'account clear and snapshot reset do not remove another account queue',
    () async {
      final other = Account(
        userId: 'u',
        server: Uri.parse('https://other.test/'),
        username: 'u',
        email: '',
        logo: '',
      );
      await journal.plan(['n']);
      await db.replaceSnapshot(
        account: other,
        notebooks: [],
        notes: [note()],
        tags: [],
        lastSyncUsn: 3,
      );
      final otherJournal = FileDownloadJournal(db.raw, other.cacheKey);
      await otherJournal.plan(['n']);
      expect((await journal.status()).notes, 1);
      await db.clearFileCache(account.cacheKey);
      expect((await journal.status()).isEmpty, isTrue);
      expect((await otherJournal.status()).notes, 1);
      await db.replaceSnapshot(
        account: other,
        notebooks: [],
        notes: [note()],
        tags: [],
        lastSyncUsn: 3,
      );
      expect((await otherJournal.status()).isEmpty, isTrue);
    },
  );

  test('quota eviction does not create an automatic redownload loop', () async {
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) => list(1),
      download: download,
      onProgress: (_, _, _) {},
    );
    await db.raw.update('note_files', {'bytes': null});
    await AccountFileCache(journal: journal).run(
      ['n'],
      listFiles: (_) async =>
          throw StateError('must not refresh completed job'),
      download: (_, _) async =>
          throw StateError('must not refill quota eviction'),
      onProgress: (_, _, errors) => expect(errors, 0),
    );
    expect((await db.fileCacheUsage(account.cacheKey)).files, 0);
  });

  test(
    'schema v9 upgrades with notes and cache preferences preserved',
    () async {
      await db.setAutoCacheFiles(account.cacheKey, true);
      await db.raw.execute('DROP TABLE cache_download_files');
      await db.raw.execute('DROP TABLE cache_download_jobs');
      await db.raw.setVersion(9);
      await reopen();
      expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
      expect(await db.autoCacheFiles(account.cacheKey), isTrue);
      expect((await db.notes(account.cacheKey)).single.title, 'Note');
      expect((await journal.plan(['n'])).single.usn, 3);
    },
  );
}
