import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../../domain/models/note_file.dart';

class DownloadJob {
  const DownloadJob(this.id, this.noteId, this.usn);
  final String id;
  final String noteId;
  final int usn;
}

class DownloadEntry {
  const DownloadEntry(this.file, this.done);
  final NoteFile file;
  final bool done;
}

class DownloadQueueStatus {
  const DownloadQueueStatus({this.notes = 0, this.files = 0, this.failed = 0});
  final int notes;
  final int files;
  final int failed;
  bool get isEmpty => notes == 0 && files == 0;
}

/// Only task metadata lives here. File bytes retain the existing cache quota,
/// membership checks and generation validation; credentials are never persisted.
class FileDownloadJournal {
  FileDownloadJournal(this.database, this.accountId);
  final Database database;
  final String accountId;

  static const schema = [
    '''CREATE TABLE IF NOT EXISTS cache_download_jobs (
      account_id TEXT NOT NULL,
      note_id TEXT NOT NULL,
      job_id TEXT NOT NULL UNIQUE,
      usn INTEGER NOT NULL,
      listed INTEGER NOT NULL DEFAULT 0,
      error TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (account_id, note_id),
      FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    )''',
    '''CREATE TABLE IF NOT EXISTS cache_download_files (
      job_id TEXT NOT NULL,
      file_id TEXT NOT NULL,
      is_attachment INTEGER NOT NULL,
      title TEXT NOT NULL,
      type TEXT NOT NULL,
      generation TEXT NOT NULL,
      done INTEGER NOT NULL DEFAULT 0,
      error TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (job_id, file_id, is_attachment),
      FOREIGN KEY (job_id) REFERENCES cache_download_jobs(job_id) ON DELETE CASCADE
    )''',
  ];

  String _id() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  String get _leaseKey => 'cache_download_lease:$accountId';
  static const _leaseDuration = Duration(minutes: 5);

  /// A SQLite transaction coordinates the UI and WorkManager isolates.
  Future<String?> claimRun() => database.transaction((txn) async {
    final rows = await txn.query(
      'app_preferences',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [_leaseKey],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rows.isNotEmpty) {
      final expiry = int.tryParse(
        (rows.single['value'] as String).split(':').last,
      );
      if (expiry != null && expiry > now) return null;
    }
    final owner = _id();
    await txn.insert('app_preferences', {
      'name': _leaseKey,
      'value': '$owner:${now + _leaseDuration.inMilliseconds}',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return owner;
  });

  Future<bool> renewRun(String owner) => database.transaction((txn) async {
    final rows = await txn.query(
      'app_preferences',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [_leaseKey],
    );
    if (rows.isEmpty ||
        !(rows.single['value'] as String).startsWith('$owner:')) {
      return false;
    }
    await txn.update(
      'app_preferences',
      {
        'value':
            '$owner:${DateTime.now().millisecondsSinceEpoch + _leaseDuration.inMilliseconds}',
      },
      where: 'name = ?',
      whereArgs: [_leaseKey],
    );
    return true;
  });

  Future<void> releaseRun(String owner) => database.delete(
    'app_preferences',
    where: 'name = ? AND value LIKE ?',
    whereArgs: [_leaseKey, '$owner:%'],
  );

  Future<List<DownloadJob>> plan(List<String> noteIds) => database.transaction((
    txn,
  ) async {
    final notes = await txn.query(
      'notes',
      columns: ['server_id', 'usn'],
      where: 'account_id = ? AND usn > 0 AND is_trash = 0 AND local_is_deleted = 0',
      whereArgs: [accountId],
    );
    final current = {
      for (final note in notes) note['server_id'] as String: note['usn'] as int,
    };
    final stored = await txn.query(
      'cache_download_jobs',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    final jobs = {for (final job in stored) job['note_id'] as String: job};
    for (final job in stored) {
      if (!current.containsKey(job['note_id'])) {
        await txn.delete(
          'cache_download_jobs',
          where: 'job_id = ?',
          whereArgs: [job['job_id']],
        );
      }
    }
    final result = <DownloadJob>[];
    for (final noteId in noteIds.toSet()) {
      final usn = current[noteId];
      if (usn == null) continue;
      final existing = jobs[noteId];
      if (existing != null && existing['usn'] == usn) {
        result.add(DownloadJob(existing['job_id'] as String, noteId, usn));
      } else {
        final id = _id();
        await txn.insert('cache_download_jobs', {
          'account_id': accountId,
          'note_id': noteId,
          'job_id': id,
          'usn': usn,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        result.add(DownloadJob(id, noteId, usn));
      }
    }
    return result;
  });

  Future<bool> _current(DatabaseExecutor txn, DownloadJob job) async {
    final rows = await txn.rawQuery(
      '''SELECT j.job_id FROM cache_download_jobs j
      JOIN notes n ON n.account_id = j.account_id AND n.server_id = j.note_id
      WHERE j.account_id = ? AND j.job_id = ? AND n.usn = ?
      AND n.is_trash = 0 AND n.local_is_deleted = 0''',
      [accountId, job.id, job.usn],
    );
    return rows.isNotEmpty;
  }

  Future<List<DownloadEntry>?> entries(DownloadJob job) =>
      database.transaction((txn) async {
        if (!await _current(txn, job)) {
          throw StateError('downloadSnapshotChanged');
        }
        final rows = await txn.query(
          'cache_download_jobs',
          where: 'job_id = ?',
          whereArgs: [job.id],
        );
        if (rows.single['listed'] != 1) return null;
        final files = await txn.query(
          'cache_download_files',
          where: 'job_id = ?',
          whereArgs: [job.id],
          orderBy: 'file_id, is_attachment',
        );
        final cached = await txn.query(
          'note_files',
          columns: ['file_id', 'is_attachment', 'generation'],
          where: 'account_id = ? AND note_id = ?',
          whereArgs: [accountId, job.noteId],
        );
        final snapshots = {
          for (final row in cached)
            '${row['file_id']}:${row['is_attachment']}': row['generation'],
        };
        // A refresh, note replacement or explicit cache clear invalidates this plan.
        if (cached.length != files.length ||
            files.any(
              (row) =>
                  snapshots['${row['file_id']}:${row['is_attachment']}'] !=
                  row['generation'],
            )) {
          await txn.delete(
            'cache_download_files',
            where: 'job_id = ?',
            whereArgs: [job.id],
          );
          await txn.update(
            'cache_download_jobs',
            {'listed': 0, 'error': ''},
            where: 'job_id = ?',
            whereArgs: [job.id],
          );
          return null;
        }
        return files
            .map(
              (row) => DownloadEntry(
                NoteFile(
                  id: row['file_id'] as String,
                  title: row['title'] as String,
                  type: row['type'] as String,
                  isAttachment: row['is_attachment'] == 1,
                  cacheGeneration: row['generation'] as String,
                ),
                row['done'] == 1,
              ),
            )
            .toList();
      });

  Future<void> saveList(DownloadJob job, List<NoteFile> files) =>
      database.transaction((txn) async {
        if (!await _current(txn, job)) {
          throw StateError('downloadSnapshotChanged');
        }
        final cached = await txn.query(
          'note_files',
          where: 'account_id = ? AND note_id = ?',
          whereArgs: [accountId, job.noteId],
        );
        final generations = {
          for (final row in cached)
            '${row['file_id']}:${row['is_attachment']}': row['generation'],
        };
        if (files.length != cached.length ||
            files.any(
              (file) =>
                  file.cacheGeneration.isEmpty ||
                  generations['${file.id}:${file.isAttachment ? 1 : 0}'] !=
                      file.cacheGeneration,
            )) {
          throw StateError('downloadSnapshotChanged');
        }
        await txn.delete(
          'cache_download_files',
          where: 'job_id = ?',
          whereArgs: [job.id],
        );
        for (final file in files) {
          await txn.insert('cache_download_files', {
            'job_id': job.id,
            'file_id': file.id,
            'is_attachment': file.isAttachment ? 1 : 0,
            'title': file.title,
            'type': file.type,
            'generation': file.cacheGeneration,
          });
        }
        await txn.update(
          'cache_download_jobs',
          {'listed': 1, 'error': ''},
          where: 'job_id = ?',
          whereArgs: [job.id],
        );
      });

  Future<void> finishFile(
    DownloadJob job,
    NoteFile file, {
    required bool success,
  }) => database.transaction((txn) async {
    if (!await _current(txn, job)) throw StateError('downloadSnapshotChanged');
    final changed = await txn.update(
      'cache_download_files',
      {'done': success ? 1 : 0, 'error': success ? '' : '下载失败，可继续重试'},
      where:
          'job_id = ? AND file_id = ? AND is_attachment = ? AND generation = ?',
      whereArgs: [
        job.id,
        file.id,
        file.isAttachment ? 1 : 0,
        file.cacheGeneration,
      ],
    );
    if (changed != 1) throw StateError('downloadSnapshotChanged');
  });

  Future<bool> hasCachedBytes(DownloadJob job, NoteFile file) async {
    final rows = await database.query(
      'note_files',
      columns: ['file_id'],
      where: 'account_id = ? AND note_id = ? AND file_id = ? AND is_attachment = ? AND generation = ? AND bytes IS NOT NULL',
      whereArgs: [
        accountId,
        job.noteId,
        file.id,
        file.isAttachment ? 1 : 0,
        file.cacheGeneration,
      ],
    );
    return rows.isNotEmpty;
  }

  Future<void> failList(DownloadJob job) async {
    await database.update(
      'cache_download_jobs',
      {'error': '读取文件列表失败，可继续重试'},
      where: 'account_id = ? AND job_id = ? AND listed = 0',
      whereArgs: [accountId, job.id],
    );
  }

  Future<DownloadQueueStatus> status() async {
    final rows = await database.rawQuery(
      '''SELECT j.listed, j.error,
      (SELECT COUNT(*) FROM cache_download_files f WHERE f.job_id = j.job_id AND f.done = 0) AS pending,
      (SELECT COUNT(*) FROM cache_download_files f WHERE f.job_id = j.job_id AND f.error != '') AS failed
      FROM cache_download_jobs j JOIN notes n ON n.account_id = j.account_id AND n.server_id = j.note_id
      WHERE j.account_id = ? AND n.is_trash = 0 AND n.local_is_deleted = 0 AND n.usn > 0''',
      [accountId],
    );
    var notes = 0, files = 0, failed = 0;
    for (final row in rows) {
      final pending = row['pending'] as int;
      if (row['listed'] == 0 || pending > 0) notes++;
      files += pending;
      failed += (row['failed'] as int) + (row['error'] == '' ? 0 : 1);
    }
    return DownloadQueueStatus(notes: notes, files: files, failed: failed);
  }
}
