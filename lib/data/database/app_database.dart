import 'large_values.dart';

import '../../domain/models/note_bundle.dart';
import '../../domain/models/note_creation_review.dart';
import '../../domain/models/notebook_conflict.dart';

import 'dart:convert';

import '../../core/async/cancellation.dart';

import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'file_download_journal.dart';
import 'attachment_outbox.dart';
import 'notebook_creation_journal.dart';
import 'note_creation_journal.dart';
import 'history_image_cache.dart';
import 'shared_file_cache.dart';
import 'file_cache_policy.dart';

import '../../domain/models/account.dart';
import '../../domain/models/attachment_upload.dart';
import '../../domain/models/default_editor.dart';
import '../../domain/models/conflict_copy.dart';
import '../../domain/models/note.dart';
import '../../domain/models/note_search_result.dart';
import '../../domain/models/note_sort.dart';
import '../../domain/models/note_file.dart';
import '../../domain/models/file_cache_usage.dart';
import '../../domain/models/note_history.dart';
import '../../domain/models/notebook.dart';
import '../../domain/models/notebook_tree.dart';
import '../../domain/models/shared_note.dart';

class AppDatabase {
  AppDatabase._(this.raw);

  static const schemaVersion = 23;
  final Database raw;

  static Future<AppDatabase> open({String? databasePath}) async {
    final filePath =
        databasePath ??
        path.join(
          (await getApplicationSupportDirectory()).path,
          'gemsnote.sqlite',
        );
    final database = await openDatabase(
      filePath,
      version: schemaVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        for (final statement in _schema) {
          await db.execute(statement);
        }
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 22) {
          final accountColumns = await db.rawQuery(
            'PRAGMA table_info(accounts)',
          );
          if (!accountColumns.any((row) => row['name'] == 'api_version')) {
            await db.execute(
              "ALTER TABLE accounts ADD COLUMN api_version TEXT NOT NULL DEFAULT ''",
            );
          }
          // Old uncertain requests have no creation key and remain manual.
          if (oldVersion >= 13) {
            final columns = await db.rawQuery(
              'PRAGMA table_info(notebook_creations)',
            );
            if (!columns.any((row) => row['name'] == 'request_json')) {
              await db.execute(
                "ALTER TABLE notebook_creations ADD COLUMN request_json TEXT NOT NULL DEFAULT ''",
              );
            }
          }
        }
        if (oldVersion < 2) await db.execute(_historySchema);
        if (oldVersion < 3) await db.execute(_avatarSchema);
        if (oldVersion < 4) await db.execute(_sharedSchema);
        if (oldVersion < 5) await db.execute(_fileCacheSchema);
        if (oldVersion < 6) await db.execute(_preferencesSchema);
        if (oldVersion < 7) await db.execute(_sortPreferencesSchema);
        // SQLite CHECK constraints require rebuilding this preferences table.
        // Existing selections and account caches must survive the upgrade.
        if (oldVersion >= 7 && oldVersion < 23) {
          await db.execute(
            'ALTER TABLE account_note_sort RENAME TO account_note_sort_previous',
          );
          await db.execute(_sortPreferencesSchema);
          await db.execute(
            'INSERT INTO account_note_sort SELECT account_id, note_sort FROM account_note_sort_previous',
          );
          await db.execute('DROP TABLE account_note_sort_previous');
        }
        if (oldVersion < 8) await db.execute(_cachePreferencesSchema);
        if (oldVersion < 9) {
          final columns = await db.rawQuery('PRAGMA table_info(notebooks)');
          if (!columns.any((row) => row['name'] == 'is_dirty')) {
            await db.execute(
              'ALTER TABLE notebooks ADD COLUMN is_dirty INTEGER NOT NULL DEFAULT 0',
            );
          }
        }
        if (oldVersion < 10) {
          for (final statement in FileDownloadJournal.schema) {
            await db.execute(statement);
          }
        }
        if (oldVersion < 11) await db.execute(AttachmentOutbox.schema);
        if (oldVersion == 11) {
          await db.execute(
            "ALTER TABLE attachment_outbox ADD COLUMN kind TEXT NOT NULL DEFAULT 'attachment'",
          );
        }
        if (oldVersion < 13) await db.execute(NotebookCreationJournal.schema);
        if (oldVersion < 14) await db.execute(NoteCreationJournal.schema);
        if (oldVersion < 15) await db.execute(HistoryImageCache.schema);
        if (oldVersion < 16) await db.execute(SharedFileCache.schema);
        if (oldVersion < 17) await db.execute(_appPreferencesSchema);
        if (oldVersion < 18) await db.execute(AttachmentOutbox.bindingSchema);
        if (oldVersion == 18) {
          await db.execute(
            'ALTER TABLE resource_bindings ADD COLUMN local_placement INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion >= 8 && oldVersion < 20) {
          final columns = await db.rawQuery(
            'PRAGMA table_info(account_cache_preferences)',
          );
          if (!columns.any((row) => row['name'] == 'auto_sync')) {
            await db.execute(
              'ALTER TABLE account_cache_preferences ADD COLUMN auto_sync INTEGER NOT NULL DEFAULT 0 CHECK (auto_sync IN (0, 1))',
            );
          }
        }
        if (oldVersion < 21) {
          final columns = await db.rawQuery(
            'PRAGMA table_info(note_histories)',
          );
          if (!columns.any((row) => row['name'] == 'is_markdown')) {
            await db.execute(
              'ALTER TABLE note_histories ADD COLUMN is_markdown INTEGER NOT NULL DEFAULT 0 CHECK (is_markdown IN (0, 1))',
            );
          }
        }
      },
    );
    return AppDatabase._(database);
  }

  Future<void> replaceNoteFiles(
    String accountId,
    String noteId,
    List<NoteFile> files,
  ) => raw.transaction((txn) async {
    final generation = _objectId();
    await txn.delete(
      'note_files',
      where: 'account_id = ? AND note_id = ?',
      whereArgs: [accountId, noteId],
    );
    for (final file in files) {
      await txn.insert('note_files', {
        'account_id': accountId,
        'note_id': noteId,
        'file_id': file.id,
        'title': file.title,
        'type': file.type,
        'is_attachment': file.isAttachment ? 1 : 0,
        'generation': generation,
      });
    }
  });

  Future<List<NoteFile>> cachedNoteFiles(
    String accountId,
    String noteId,
  ) async {
    final rows = await raw.query(
      'note_files',
      where: 'account_id = ? AND note_id = ?',
      whereArgs: [accountId, noteId],
      orderBy: 'title, file_id',
    );
    return rows
        .map(
          (row) => NoteFile(
            id: row['file_id'] as String,
            title: row['title'] as String,
            type: row['type'] as String,
            isAttachment: row['is_attachment'] == 1,
            cacheGeneration: row['generation'] as String,
          ),
        )
        .toList();
  }

  Future<FileCacheUsage> fileCacheUsage(String accountId) async {
    final rows = await raw.rawQuery(
      'SELECT COUNT(*) AS files, COALESCE(SUM(length(bytes)), 0) AS size '
      'FROM (SELECT bytes FROM note_files WHERE account_id = ? AND bytes IS NOT NULL '
      'UNION ALL SELECT bytes FROM history_images WHERE account_id = ? AND bytes IS NOT NULL '
      'UNION ALL SELECT bytes FROM shared_files WHERE account_id = ? AND bytes IS NOT NULL)',
      [accountId, accountId, accountId],
    );
    return FileCacheUsage(
      files: rows.single['files'] as int,
      bytes: rows.single['size'] as int,
      pendingDownloads: (await FileDownloadJournal(
        raw,
        accountId,
      ).status()).notes,
    );
  }

  Future<void> clearFileCache(String accountId) async {
    // Rotate every row, including files not yet cached, so in-flight downloads
    // cannot refill this account using a pre-clear generation.
    await raw.transaction((txn) async {
      await txn.update(
        'note_files',
        {'bytes': null, 'cached_at': 0, 'generation': _objectId()},
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      await SharedFileCache.clear(txn, accountId);
      await txn.delete(
        'history_images',
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      await txn.delete(
        'cache_download_jobs',
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
    });
  }

  Future<Uint8List> cachedNoteImage(
    String accountId,
    String noteId,
    NoteFile file,
  ) => _cachedNoteFile(accountId, noteId, file, false);

  Future<Uint8List> cachedNoteAttachment(
    String accountId,
    String noteId,
    NoteFile file,
  ) => _cachedNoteFile(accountId, noteId, file, true);

  Future<Uint8List> _cachedNoteFile(
    String accountId,
    String noteId,
    NoteFile file,
    bool attachment,
  ) async {
    final rows = await raw.query(
      'note_files',
      columns: ['bytes'],
      where: 'account_id = ? AND note_id = ? AND file_id = ? AND generation = ? AND is_attachment = ?',
      whereArgs: [
        accountId,
        noteId,
        file.id,
        file.cacheGeneration,
        attachment ? 1 : 0,
      ],
    );
    if (rows.isEmpty || rows.single['bytes'] == null) {
      throw StateError('文件尚未缓存或缓存已失效，请联网下载');
    }
    return rows.single['bytes'] as Uint8List;
  }

  Future<void> cacheNoteImage(
    String accountId,
    String noteId,
    NoteFile file,
    Uint8List bytes,
  ) => _cacheNoteFile(accountId, noteId, file, bytes, false);

  Future<void> cacheNoteAttachment(
    String accountId,
    String noteId,
    NoteFile file,
    Uint8List bytes,
  ) => _cacheNoteFile(accountId, noteId, file, bytes, true);

  Future<void> _cacheNoteFile(
    String accountId,
    String noteId,
    NoteFile file,
    Uint8List bytes,
    bool attachment,
  ) => raw.transaction((txn) async {
    if ((!attachment && bytes.isEmpty) ||
        bytes.length > (attachment ? 32 : 8) * 1024 * 1024) {
      throw StateError('invalidFileSize');
    }
    final changed = await txn.update(
      'note_files',
      {'bytes': bytes, 'cached_at': DateTime.now().microsecondsSinceEpoch},
      where: 'account_id = ? AND note_id = ? AND file_id = ? AND generation = ? AND is_attachment = ?',
      whereArgs: [
        accountId,
        noteId,
        file.id,
        file.cacheGeneration,
        attachment ? 1 : 0,
      ],
    );
    if (changed != 1) throw StateError('文件列表已变化，请刷新后重试');
    await enforceFileCacheBudget(txn);
  });

  Future<void> replaceSharedSnapshot(
    String accountId,
    List<SharedNote> notes,
  ) => raw.transaction((txn) async {
    final previous = await txn.queryLargeValues(
      'shared_notes',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    final old = {for (final row in previous) row['note_id']: row};
    final ids = notes.map((note) => note.note.noteId).toSet();
    if (ids.length != notes.length) throw StateError('duplicateSharedNotes');
    for (final row in previous) {
      if (!ids.contains(row['note_id'])) {
        await txn.delete(
          'shared_notes',
          where: 'account_id=? AND note_id=?',
          whereArgs: [accountId, row['note_id']],
        );
      }
    }
    for (final shared in notes) {
      final existing = old[shared.note.noteId];
      final values = <String, Object?>{
        'account_id': accountId,
        'note_id': shared.note.noteId,
        'owner_id': shared.note.userId,
        'version': shared.version,
        'metadata': jsonEncode(shared.toJson()),
        'content':
            existing != null &&
                existing['version'] == shared.version &&
                existing['owner_id'] == shared.note.userId
            ? existing['content']
            : null,
      };
      if (existing == null) {
        await txn.insert('shared_notes', values);
      } else {
        await txn.update(
          'shared_notes',
          values,
          where: 'account_id=? AND note_id=?',
          whereArgs: [accountId, shared.note.noteId],
        );
      }
      await SharedFileCache.replace(
        txn,
        accountId,
        shared,
        preserve:
            existing != null && existing['owner_id'] == shared.note.userId,
      );
    }
  });

  Future<List<SharedNote>> cachedSharedNotes(String accountId) async {
    final rows = await raw.queryLargeValues(
      'shared_notes',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'note_id',
    );
    final result = rows
        .map(
          (row) => SharedNote.fromJson(
            Map<String, Object?>.from(
              jsonDecode(row['metadata'] as String) as Map,
            ),
          ),
        )
        .toList();
    result.sort((a, b) {
      final cmp = a.note.title.toLowerCase().compareTo(
        b.note.title.toLowerCase(),
      );
      return cmp == 0 ? a.note.noteId.compareTo(b.note.noteId) : cmp;
    });
    return result;
  }

  Future<void> cacheSharedContent(
    String accountId,
    SharedNote note,
    String content,
  ) async {
    final changed = await raw.update(
      'shared_notes',
      {'content': content},
      where: 'account_id = ? AND note_id = ? AND owner_id = ? AND version = ?',
      whereArgs: [accountId, note.note.noteId, note.note.userId, note.version],
    );
    if (changed != 1) throw StateError('共享列表已变化，请刷新后重试');
  }

  Future<Note> cachedSharedContent(String accountId, SharedNote note) async {
    final rows = await raw.queryLargeValues(
      'shared_notes',
      where: 'account_id = ? AND note_id = ? AND owner_id = ? AND version = ?',
      whereArgs: [accountId, note.note.noteId, note.note.userId, note.version],
    );
    if (rows.isEmpty || rows.single['content'] == null) {
      throw StateError('此共享正文尚未缓存或已失效，请联网刷新后查看');
    }
    final current = SharedNote.fromJson(
      Map<String, Object?>.from(
        jsonDecode(rows.single['metadata'] as String) as Map,
      ),
    );
    return current.note.copyWith(content: rows.single['content'] as String);
  }

  Future<void> removeSharedNote(
    String accountId,
    String noteId, {
    SharedNote? expected,
  }) async {
    await raw.delete(
      'shared_notes',
      where:
          'account_id = ? AND note_id = ?${expected == null ? '' : ' AND owner_id = ? AND version = ?'}',
      whereArgs: [
        accountId,
        noteId,
        if (expected != null) ...[expected.note.userId, expected.version],
      ],
    );
  }

  Future<List<Account>> cachedAccounts() async {
    final rows = await raw.query(
      'accounts',
      orderBy: 'server, username, user_id',
    );
    return Future.wait(
      rows
          .map(
            (row) => cachedProfile(
              Account(
                userId: row['user_id']! as String,
                server: Uri.parse(row['server']! as String),
                username: row['username']! as String,
                email: row['email']! as String,
                logo: row['logo']! as String,
                apiVersion: row['api_version']! as String,
              ),
            ),
          )
          .toList(),
    );
  }

  Future<Account?> activeAccount() async {
    final rows = await raw.query('accounts', where: 'is_active = 1', limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return cachedProfile(
      Account(
        userId: row['user_id']! as String,
        server: Uri.parse(row['server']! as String),
        username: row['username']! as String,
        email: row['email']! as String,
        logo: row['logo']! as String,
        apiVersion: row['api_version']! as String,
      ),
    );
  }

  Future<String> languagePreference() async {
    final rows = await raw.query(
      'app_preferences',
      columns: ['value'],
      where: 'name=?',
      whereArgs: ['language'],
    );
    final value = rows.isEmpty ? 'system' : rows.single['value'] as String;
    return {'system', 'zh', 'en'}.contains(value) ? value : 'system';
  }

  Future<void> setLanguagePreference(String value) async {
    if (!{'system', 'zh', 'en'}.contains(value)) {
      throw ArgumentError.value(value, 'language');
    }
    await raw.insert('app_preferences', {
      'name': 'language',
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> appLockEnabled() async {
    final rows = await raw.query(
      'app_preferences',
      columns: ['value'],
      where: 'name=?',
      whereArgs: ['app_lock'],
    );
    return rows.isNotEmpty && rows.single['value'] == 'true';
  }

  Future<void> setAppLockEnabled(bool value) => raw.insert('app_preferences', {
    'name': 'app_lock',
    'value': value.toString(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static const _appPreferencesSchema =
      'CREATE TABLE IF NOT EXISTS app_preferences (name TEXT PRIMARY KEY, value TEXT NOT NULL)';

  Future<bool> autoCacheFiles(String accountId) async {
    final rows = await raw.query(
      'account_cache_preferences',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    return rows.isNotEmpty && rows.single['enabled'] == 1;
  }

  Future<void> setAutoCacheFiles(String accountId, bool enabled) =>
      raw.transaction((txn) async {
        final accounts = await txn.query(
          'accounts',
          columns: ['account_id'],
          where: 'account_id = ?',
          whereArgs: [accountId],
        );
        if (accounts.isEmpty) throw StateError('accountCacheMissing');
        await txn.rawInsert(
          '''INSERT INTO account_cache_preferences (account_id, enabled)
          VALUES (?, ?) ON CONFLICT(account_id) DO UPDATE SET enabled = excluded.enabled''',
          [accountId, enabled ? 1 : 0],
        );
      });

  Future<bool> autoSync(String accountId) async {
    final rows = await raw.query(
      'account_cache_preferences',
      columns: ['auto_sync'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    return rows.isNotEmpty && rows.single['auto_sync'] == 1;
  }

  Future<void> setAutoSync(String accountId, bool enabled) => raw.transaction((
    txn,
  ) async {
    final accounts = await txn.query(
      'accounts',
      columns: ['account_id'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    if (accounts.isEmpty) throw StateError('accountCacheMissing');
    await txn.rawInsert(
      '''INSERT INTO account_cache_preferences (account_id, enabled, auto_sync)
          VALUES (?, 0, ?) ON CONFLICT(account_id) DO UPDATE SET auto_sync = excluded.auto_sync''',
      [accountId, enabled ? 1 : 0],
    );
  });

  Future<NoteSort> noteSort(String accountId) async {
    final rows = await raw.query(
      'account_note_sort',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    return rows.isEmpty
        ? NoteSort.updatedDescending
        : NoteSort.values.byName(rows.single['note_sort']! as String);
  }

  Future<void> setNoteSort(String accountId, NoteSort sort) =>
      raw.transaction((txn) async {
        final accounts = await txn.query(
          'accounts',
          columns: ['account_id'],
          where: 'account_id = ?',
          whereArgs: [accountId],
        );
        if (accounts.isEmpty) throw StateError('accountCacheMissing');
        await txn.insert('account_note_sort', {
          'account_id': accountId,
          'note_sort': sort.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<DefaultEditor> defaultEditor(String accountId) async {
    final rows = await raw.query(
      'account_preferences',
      columns: ['default_editor'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    if (rows.isEmpty) return DefaultEditor.html;
    return DefaultEditor.values.byName(
      rows.single['default_editor']! as String,
    );
  }

  Future<void> setDefaultEditor(String accountId, DefaultEditor editor) =>
      raw.transaction((txn) async {
        final account = await txn.query(
          'accounts',
          columns: ['account_id'],
          where: 'account_id = ?',
          whereArgs: [accountId],
        );
        if (account.isEmpty) throw StateError('accountCacheMissing');
        await txn.insert('account_preferences', {
          'account_id': accountId,
          'default_editor': editor.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<int> lastSyncUsn(String accountId) async {
    final rows = await raw.query(
      'accounts',
      columns: ['last_sync_usn'],
      where: 'account_id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.single['last_sync_usn']! as int;
  }

  /// Individual upload acknowledgements can be ahead of the download cursor.
  Future<int> knownSyncUsn(String accountId) async {
    final rows = await raw.rawQuery(
      '''SELECT COALESCE(MAX(usn), 0) AS known FROM (
      SELECT last_sync_usn AS usn FROM accounts WHERE account_id = ?
      UNION ALL SELECT usn FROM notes WHERE account_id = ?
      UNION ALL SELECT usn FROM notebooks WHERE account_id = ?
      UNION ALL SELECT usn FROM tags WHERE account_id = ?
    )''',
      List.filled(4, accountId),
    );
    return rows.single['known'] as int;
  }

  Future<bool> hasAccountCache(String accountId) async => (await raw.query(
    'accounts',
    columns: ['account_id'],
    where: 'account_id = ?',
    whereArgs: [accountId],
    limit: 1,
  )).isNotEmpty;

  Future<Account> cachedProfile(Account fallback) async {
    final rows = await raw.query(
      'accounts',
      where: 'account_id = ?',
      whereArgs: [fallback.cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return fallback;
    final row = rows.single;
    final details = await accountMetadata(fallback.cacheKey, 'profile');
    return Account(
      verified: details.containsKey('Verified')
          ? details['Verified'] == true
          : fallback.verified,
      pendingEmail:
          details['PendingEmail']?.toString() ?? fallback.pendingEmail,
      userId: fallback.userId,
      server: fallback.server,
      username: row['username'] as String,
      email: row['email'] as String,
      logo: row['logo'] as String,
      apiVersion: row['api_version'] as String,
    );
  }

  Future<Uint8List?> cachedAvatar(String accountId) async {
    final rows = await raw.query(
      'account_avatars',
      columns: ['bytes'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    return rows.isEmpty ? null : rows.single['bytes'] as Uint8List;
  }

  Future<void> cacheAvatar(String accountId, Uint8List? bytes) async {
    if (bytes == null) {
      await raw.delete(
        'account_avatars',
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
    } else {
      await raw.insert('account_avatars', {
        'account_id': accountId,
        'bytes': bytes,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<Map<String, Object?>> accountMetadata(
    String accountId,
    String kind,
  ) async {
    final rows = await raw.query(
      'app_preferences',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: ['$kind:$accountId'],
    );
    return rows.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(
            jsonDecode(rows.single['value'] as String) as Map,
          );
  }

  Future<void> setAccountMetadata(
    String accountId,
    String kind,
    Map<String, Object?> data,
  ) => raw
      .insert('app_preferences', {
        'name': '$kind:$accountId',
        'value': jsonEncode(data),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<void> updateProfile(Account account) async {
    await setAccountMetadata(account.cacheKey, 'profile', {
      'Verified': account.verified,
      'PendingEmail': account.pendingEmail,
    });
    await raw.update(
      'accounts',
      {
        'username': account.username,
        'email': account.email,
        'logo': account.logo,
      },
      where: 'account_id = ?',
      whereArgs: [account.cacheKey],
    );
  }

  Future<void> activateCachedAccount(Account account) async {
    await raw.transaction((txn) async {
      await txn.update('accounts', {'is_active': 0});
      final changed = await txn.update(
        'accounts',
        {
          'is_active': 1,
          'username': account.username,
          'email': account.email,
          'logo': account.logo,
          'api_version': account.apiVersion,
        },
        where: 'account_id = ?',
        whereArgs: [account.cacheKey],
      );
      if (changed != 1) throw StateError('accountCacheMissing');
      await txn.insert('app_preferences', {
        'name': 'profile:${account.cacheKey}',
        'value': jsonEncode({
          'Verified': account.verified,
          'PendingEmail': account.pendingEmail,
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // Include notebooks as reset can discard their offline edits too.
  Future<String> noteSnapshotFingerprint(String accountId) =>
      raw.transaction((txn) => _snapshotFingerprint(txn, accountId));

  static Future<String> _snapshotFingerprint(
    DatabaseExecutor db,
    String accountId,
  ) async => jsonEncode([
    for (final table in ['notes', 'notebooks'])
      await db.queryLargeValues(
        table,
        where: 'account_id = ?',
        whereArgs: [accountId],
        orderBy: 'server_id',
      ),
  ]);

  Future<void> replaceSnapshot({
    required Account account,
    required List<Notebook> notebooks,
    required List<Note> notes,
    required List<Map<String, Object?>> tags,
    required int lastSyncUsn,
    String? expectedNoteSnapshot,
  }) async {
    await raw.transaction((txn) async {
      Cancellation.current?.check();
      final pending = await txn.queryLargeValues(
        'notes',
        columns: ['server_id'],
        where: 'account_id = ? AND is_dirty = 1',
        whereArgs: [account.cacheKey],
        limit: 1,
      );
      if (expectedNoteSnapshot == null) {
        final pendingBooks = await txn.query(
          'notebooks',
          columns: ['server_id'],
          where: 'account_id = ? AND is_dirty = 1',
          whereArgs: [account.cacheKey],
          limit: 1,
        );
        if (pending.isNotEmpty || pendingBooks.isNotEmpty) {
          throw StateError('请先同步待处理的笔记修改，再删除标签');
        }
      } else {
        final current = await _snapshotFingerprint(txn, account.cacheKey);
        if (current != expectedNoteSnapshot) {
          throw StateError('localChangesDuringReset');
        }
      }
      final batch = txn.batch();
      batch.update('accounts', {'is_active': 0});
      batch.insert('accounts', {
        'account_id': account.cacheKey,
        'user_id': account.userId,
        'server': account.server.toString(),
        'username': account.username,
        'email': account.email,
        'logo': account.logo,
        'last_sync_usn': lastSyncUsn,
        'api_version': account.apiVersion,
        'is_active': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('app_preferences', {
        'name': 'profile:${account.cacheKey}',
        'value': jsonEncode({
          'Verified': account.verified,
          'PendingEmail': account.pendingEmail,
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final table in ['notebooks', 'notes', 'tags']) {
        batch.delete(
          table,
          where: 'account_id = ?',
          whereArgs: [account.cacheKey],
        );
      }
      for (final notebook in notebooks.where((item) => !item.isDeleted)) {
        batch.insert('notebooks', {
          'account_id': account.cacheKey,
          'server_id': notebook.notebookId,
          'parent_server_id': notebook.parentNotebookId,
          'title': notebook.title,
          'sequence': notebook.sequence,
          'usn': notebook.usn,
          'number_notes': notebook.numberNotes,
        });
      }
      for (final note in notes.where((item) => !item.isDeleted)) {
        batch.insert('notes', {
          'account_id': account.cacheKey,
          'server_id': note.noteId,
          'notebook_server_id': note.notebookId,
          'owner_server_id': note.userId,
          'title': note.title,
          'content': note.content,
          'tags_json': jsonEncode(note.tags),
          'usn': note.usn,
          'is_markdown': note.isMarkdown ? 1 : 0,
          'is_starred': note.isStarred ? 1 : 0,
          'is_trash': note.isTrash ? 1 : 0,
          'created_time': note.createdTime,
          'updated_time': note.updatedTime,
          'is_dirty': 0,
          'local_is_new': 0,
          'local_is_deleted': 0,
        });
      }
      for (final tag in tags.where((item) => item['IsDeleted'] != true)) {
        final name = tag['Tag']?.toString() ?? tag['Title']?.toString() ?? '';
        if (name.isEmpty) continue;
        batch.insert('tags', {
          'account_id': account.cacheKey,
          'name': name,
          'usn': _integer(tag['Usn']),
        });
      }
      Cancellation.current?.check();
      await batch.commit(noResult: true);
      Cancellation.current?.check();
    });
  }

  Future<void> mergeChanges({
    required Account account,
    required List<Notebook> notebooks,
    required List<Note> notes,
    required List<Map<String, Object?>> tags,
    required int lastSyncUsn,
  }) async {
    await raw.transaction((txn) async {
      Cancellation.current?.check();
      // New edits may have been saved while the network requests were running.
      // Keep the cursor unchanged so this remote page is retried next time.
      for (final note in notes) {
        final pending = await txn.queryLargeValues(
          'notes',
          columns: ['server_id'],
          where: 'account_id = ? AND server_id = ? AND is_dirty = 1',
          whereArgs: [account.cacheKey, note.noteId],
          limit: 1,
        );
        if (pending.isNotEmpty) throw StateError('localChangesDuringSync');
      }
      for (final notebook in notebooks) {
        final pending = await txn.query(
          'notebooks',
          columns: ['server_id'],
          where: 'account_id = ? AND server_id = ? AND is_dirty = 1',
          whereArgs: [account.cacheKey, notebook.notebookId],
          limit: 1,
        );
        if (pending.isNotEmpty) throw StateError('localChangesDuringSync');
      }
      final batch = txn.batch();
      for (final notebook in notebooks) {
        if (notebook.isDeleted) {
          batch.delete(
            'notebooks',
            where: 'account_id = ? AND server_id = ?',
            whereArgs: [account.cacheKey, notebook.notebookId],
          );
        } else {
          batch.insert('notebooks', {
            'account_id': account.cacheKey,
            'server_id': notebook.notebookId,
            'parent_server_id': notebook.parentNotebookId,
            'title': notebook.title,
            'sequence': notebook.sequence,
            'usn': notebook.usn,
            'number_notes': notebook.numberNotes,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (final note in notes) {
        if (note.isDeleted) {
          batch.delete(
            'note_histories',
            where: 'account_id = ? AND note_id = ?',
            whereArgs: [account.cacheKey, note.noteId],
          );
          batch.delete(
            'notes',
            where: 'account_id = ? AND server_id = ?',
            whereArgs: [account.cacheKey, note.noteId],
          );
        } else {
          _insertNote(batch, account.cacheKey, note);
        }
      }
      for (final tag in tags) {
        final name = tag['Tag']?.toString() ?? tag['Title']?.toString() ?? '';
        if (name.isEmpty) continue;
        if (tag['IsDeleted'] == true) {
          batch.delete(
            'tags',
            where: 'account_id = ? AND name = ?',
            whereArgs: [account.cacheKey, name],
          );
        } else {
          batch.insert('tags', {
            'account_id': account.cacheKey,
            'name': name,
            'usn': _integer(tag['Usn']),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      batch.update(
        'accounts',
        {'last_sync_usn': lastSyncUsn},
        where: 'account_id = ?',
        whereArgs: [account.cacheKey],
      );
      Cancellation.current?.check();
      await batch.commit(noResult: true);
      Cancellation.current?.check();
    });
  }

  Future<List<Notebook>> notebooks(String accountId) async {
    final rows = await raw.rawQuery(
      '''SELECT notebooks.*,
        (SELECT COUNT(*) FROM notes
          WHERE notes.account_id = notebooks.account_id
            AND notes.notebook_server_id = notebooks.server_id
            AND notes.is_trash = 0
            AND notes.local_is_deleted = 0) AS actual_number_notes
        FROM notebooks
        WHERE notebooks.account_id = ?
        ORDER BY notebooks.title COLLATE NOCASE, notebooks.server_id''',
      [accountId],
    );
    return rows
        .map(
          (row) => Notebook(
            notebookId: row['server_id']! as String,
            parentNotebookId: row['parent_server_id']! as String,
            title: row['title']! as String,
            sequence: row['sequence']! as int,
            usn: row['usn']! as int,
            numberNotes: row['actual_number_notes']! as int,
            isDirty: row['is_dirty'] == 1,
            isDeleted: false,
          ),
        )
        .toList(growable: false);
  }

  static Notebook _notebookFromRow(Map<String, Object?> row) => Notebook(
    notebookId: row['server_id']! as String,
    parentNotebookId: row['parent_server_id']! as String,
    title: row['title']! as String,
    sequence: row['sequence']! as int,
    usn: row['usn']! as int,
    numberNotes: row['number_notes']! as int,
    isDeleted: false,
    isDirty: row['is_dirty'] == 1,
  );

  Future<List<Notebook>> dirtyNotebooks(String accountId) async =>
      (await raw.query(
        'notebooks',
        where: 'account_id = ? AND is_dirty = 1',
        whereArgs: [accountId],
        orderBy: 'server_id',
      )).map(_notebookFromRow).toList();

  Future<void> editLocalNotebook(
    String accountId,
    String notebookId, {
    String? title,
    String? parentId,
  }) => raw.transaction((txn) async {
    final creations = NotebookCreationJournal(raw, accountId);
    notebookId = await creations.resolve(notebookId, transaction: txn);
    final rows = await txn.query(
      'notebooks',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    final books = rows.map(_notebookFromRow).toList();
    final source = books.where((n) => n.notebookId == notebookId).firstOrNull;
    if (source == null) throw StateError('notebookMissing');
    if (source.usn <= 0 &&
        await creations.state(notebookId, transaction: txn) != 'pending') {
      throw StateError('请先核实笔记本创建结果，再修改名称或位置');
    }
    final nextTitle = title?.trim() ?? source.title;
    if (nextTitle.isEmpty) throw const FormatException('请输入笔记本名称');
    final nextParent = parentId == null
        ? source.parentNotebookId
        : await creations.resolve(parentId, transaction: txn);
    if (nextParent != source.parentNotebookId &&
        !canMoveNotebook(books, notebookId, nextParent)) {
      throw const FormatException('目标笔记本无效，不能移到自身、子级或循环层级下');
    }
    if (source.title == nextTitle && source.parentNotebookId == nextParent) {
      return;
    }
    await txn.update(
      'notebooks',
      {'title': nextTitle, 'parent_server_id': nextParent, 'is_dirty': 1},
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, notebookId],
    );
  });

  /// Resolve the reviewed notebook and its required clean ancestors. Note bodies,
  /// dirty ancestors and the global cursor are never replaced.
  Future<void> resolveNotebookConflict(
    String accountId,
    NotebookConflictSnapshot reviewed, {
    required bool keepLocal,
  }) => raw.transaction((txn) async {
    if (reviewed.accountId != accountId) {
      throw StateError('notebookConflictAccount');
    }
    final rows = await txn.query(
      'notebooks',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    final books = rows.map(_notebookFromRow).toList();
    final current = books
        .where((n) => n.notebookId == reviewed.local.notebookId)
        .firstOrNull;
    if (current == null ||
        !current.isDirty ||
        current.usn <= 0 ||
        !sameNotebookVersion(current, reviewed.local)) {
      throw StateError('notebookConflictLocalChanged');
    }
    final remote = reviewed.remote;
    if (remote.notebookId != current.notebookId ||
        remote.isDeleted ||
        remote.usn < current.usn) {
      throw StateError('notebookConflictRemoteUnavailable');
    }
    final selected = keepLocal ? current : remote;
    final byId = {for (final book in books) book.notebookId: book};
    final remoteById = {
      for (final book in reviewed.remoteBooks) book.notebookId: book,
    };
    final ancestors = <Notebook>[];
    final visited = <String>{current.notebookId};
    var parent = selected.parentNotebookId;
    while (parent.isNotEmpty) {
      if (!visited.add(parent)) throw StateError('notebookConflictHierarchy');
      var book = byId[parent];
      if (!keepLocal && (book == null || !book.isDirty)) {
        final fresh = remoteById[parent];
        if (fresh == null ||
            fresh.isDeleted ||
            fresh.usn <= 0 ||
            (book != null &&
                (fresh.usn < book.usn ||
                    (fresh.usn == book.usn &&
                        !sameNotebookVersion(fresh, book))))) {
          throw StateError('notebookConflictHierarchy');
        }
        ancestors.add(fresh);
        book = fresh;
      }
      if (book == null || book.isDeleted || book.usn < 0) {
        throw StateError('notebookConflictHierarchy');
      }
      parent = book.parentNotebookId;
    }
    // Refresh only the required ancestors without local changes. Never REPLACE
    // their rows: resources and notes may refer to them through foreign keys.
    for (final book in ancestors.reversed) {
      final values = <String, Object?>{
        'account_id': accountId,
        'server_id': book.notebookId,
        'parent_server_id': book.parentNotebookId,
        'title': book.title,
        'sequence': book.sequence,
        'usn': book.usn,
        'number_notes': book.numberNotes,
      };
      if (byId.containsKey(book.notebookId)) {
        await txn.update(
          'notebooks',
          values,
          where: 'account_id = ? AND server_id = ?',
          whereArgs: [accountId, book.notebookId],
        );
      } else {
        await txn.insert('notebooks', values);
      }
    }
    final differs =
        selected.title != remote.title ||
        selected.parentNotebookId != remote.parentNotebookId ||
        selected.sequence != remote.sequence;
    await txn.update(
      'notebooks',
      {
        'title': selected.title,
        'parent_server_id': selected.parentNotebookId,
        'sequence': selected.sequence,
        'usn': remote.usn,
        'number_notes': remote.numberNotes,
        'is_dirty': differs ? 1 : 0,
      },
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, current.notebookId],
    );
  });

  Future<void> markNotebookUploaded(
    String accountId,
    Notebook local,
    Notebook remote,
  ) => raw.transaction((txn) async {
    if (remote.notebookId != local.notebookId ||
        remote.usn <= local.usn ||
        remote.isDeleted ||
        remote.title != local.title ||
        remote.parentNotebookId != local.parentNotebookId ||
        remote.sequence != local.sequence) {
      throw StateError('invalidNotebookUploadResponse');
    }
    final rows = await txn.query(
      'notebooks',
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, local.notebookId],
    );
    if (rows.isEmpty) throw StateError('notebookMissing');
    final current = _notebookFromRow(rows.single);
    if (current.usn != local.usn) throw StateError('localChangesDuringSync');
    final unchanged =
        current.title == local.title &&
        current.parentNotebookId == local.parentNotebookId &&
        current.sequence == local.sequence;
    await txn.update(
      'notebooks',
      {
        'usn': remote.usn,
        'number_notes': remote.numberNotes,
        'is_dirty': unchanged ? 0 : 1,
      },
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, local.notebookId],
    );
  });

  Future<void> cacheNotebook(
    String accountId,
    Notebook notebook,
  ) => raw.transaction((txn) async {
    // Do not advance the global cursor: other remote changes may precede this
    // write and still need to be downloaded by the next sync.
    final pending = await txn.query(
      'notebooks',
      columns: ['server_id'],
      where: 'account_id = ? AND server_id = ? AND is_dirty = 1',
      whereArgs: [accountId, notebook.notebookId],
    );
    if (pending.isNotEmpty) throw StateError('localChangesDuringSync');
    await txn.insert('notebooks', {
      'account_id': accountId,
      'server_id': notebook.notebookId,
      'parent_server_id': notebook.parentNotebookId,
      'title': notebook.title,
      'sequence': notebook.sequence,
      'usn': notebook.usn,
      'number_notes': notebook.numberNotes,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<void> cacheTag(String accountId, String name, int usn) async {
    await raw.transaction((txn) async {
      final existing = await txn.query(
        'tags',
        columns: ['usn'],
        where: 'account_id = ? AND name = ?',
        whereArgs: [accountId, name],
      );
      if (existing.isNotEmpty && (existing.single['usn'] as int) > usn) {
        return;
      }
      await txn.insert('tags', {
        'account_id': accountId,
        'name': name,
        'usn': usn,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<int> tagUsn(String accountId, String name) async {
    final rows = await raw.query(
      'tags',
      columns: ['usn'],
      where: 'account_id = ? AND name = ?',
      whereArgs: [accountId, name],
      limit: 1,
    );
    if (rows.length != 1) throw StateError('同步目录中没有此标签，请同步后重试');
    return rows.single['usn'] as int;
  }

  Future<bool> hasTagReferences(String accountId, String name) async {
    final rows = await raw.queryLargeValues(
      'notes',
      columns: ['tags_json'],
      where: 'account_id = ? AND local_is_deleted = 0',
      whereArgs: [accountId],
    );
    return rows.any(
      (row) => (jsonDecode(row['tags_json'] as String) as List).contains(name),
    );
  }

  Future<void> replaceTagInNotes(
    String accountId,
    String oldName,
    String newName,
  ) => raw.transaction((txn) async {
    final rows = await txn.queryLargeValues(
      'notes',
      columns: ['server_id', 'tags_json'],
      where: 'account_id = ? AND local_is_deleted = 0',
      whereArgs: [accountId],
    );
    for (final row in rows) {
      final tags = (jsonDecode(row['tags_json'] as String) as List)
          .cast<String>();
      if (!tags.contains(oldName)) continue;
      final replaced = <String>[];
      for (final tag in tags) {
        final value = tag == oldName ? newName : tag;
        if (value.isNotEmpty && !replaced.contains(value)) replaced.add(value);
      }
      await txn.update(
        'notes',
        {
          'tags_json': jsonEncode(replaced),
          'updated_time': DateTime.now().toUtc().toIso8601String(),
          'is_dirty': 1,
        },
        where: 'account_id = ? AND server_id = ?',
        whereArgs: [accountId, row['server_id']],
      );
    }
  });

  Future<Map<String, int>> tagCounts(
    String accountId, {
    bool includeUnused = false,
  }) async {
    final rows = await raw.queryLargeValues(
      'notes',
      columns: ['tags_json'],
      where: 'account_id = ? AND is_trash = 0 AND local_is_deleted = 0',
      whereArgs: [accountId],
    );
    final counts = <String, int>{};
    if (includeUnused) {
      final catalog = await raw.query(
        'tags',
        columns: ['name'],
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      for (final row in catalog) {
        final name = row['name'] as String;
        if (name.trim().isNotEmpty) counts[name] = 0;
      }
    }
    for (final row in rows) {
      final tags = (jsonDecode(row['tags_json'] as String) as List)
          .cast<String>()
          .where((tag) => tag.trim().isNotEmpty)
          .toSet();
      for (final tag in tags) {
        counts.update(tag, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final names = counts.keys.toList()
      ..sort((a, b) {
        final order = a.toLowerCase().compareTo(b.toLowerCase());
        return order == 0 ? a.compareTo(b) : order;
      });
    return {for (final name in names) name: counts[name]!};
  }

  Future<List<Note>> notesForTag(String accountId, String tag) async {
    if (tag.trim().isEmpty) return [];
    return (await notes(accountId))
        .where((note) => note.tags.contains(tag))
        .toList(growable: false);
  }

  Future<List<Note>> notes(
    String accountId, {
    String? notebookId,
    bool starredOnly = false,
    bool trashOnly = false,
  }) async {
    final clauses = <String>[
      'account_id = ?',
      'local_is_deleted = 0',
      trashOnly ? 'is_trash = 1' : 'is_trash = 0',
    ];
    final arguments = <Object?>[accountId];
    if (notebookId != null) {
      clauses.add('notebook_server_id = ?');
      arguments.add(
        await NotebookCreationJournal(raw, accountId).resolve(notebookId),
      );
    }
    if (starredOnly) clauses.add('is_starred = 1');
    final rows = await raw.queryLargeValues(
      'notes',
      where: clauses.join(' AND '),
      whereArgs: arguments,
      orderBy: 'updated_time DESC, server_id',
    );
    return rows.map(_noteFromRow).toList(growable: false);
  }

  Future<List<Note>> searchNotes(
    String accountId,
    String query, {
    int limit = 50,
  }) async => (await _searchRows(
    accountId,
    query,
    limit: limit,
  )).map(_noteFromRow).toList(growable: false);

  Future<List<NoteSearchResult>> searchNoteSummaries(
    String accountId,
    String query, {
    int limit = 50,
  }) async =>
      (await _searchRows(
            accountId,
            query,
            limit: limit,
            columns: ['server_id', 'title', 'updated_time', 'is_markdown'],
          ))
          .map(
            (row) => NoteSearchResult(
              noteId: row['server_id']! as String,
              title: row['title']! as String,
              updatedTime: row['updated_time']! as String,
              isMarkdown: row['is_markdown'] == 1,
            ),
          )
          .toList(growable: false);

  /// Re-read one result when it is opened, including concurrent local changes.
  Future<Note?> searchableNote(String accountId, String noteId) async {
    final rows = await raw.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND is_trash = 0 AND local_is_deleted = 0',
      whereArgs: [accountId, noteId],
      limit: 1,
    );
    return rows.isEmpty ? null : _noteFromRow(rows.single);
  }

  Future<List<Map<String, Object?>>> _searchRows(
    String accountId,
    String query, {
    required int limit,
    List<String>? columns,
  }) async {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final escaped = query
        .replaceAll('\\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final pattern = '%$escaped%';
    return raw.queryLargeValues(
      'notes',
      columns: columns,
      where: '''account_id = ? AND is_trash = 0 AND local_is_deleted = 0
        AND (title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')''',
      whereArgs: [accountId, pattern, pattern],
      orderBy: 'updated_time DESC, server_id',
      limit: limit,
    );
  }

  Future<Note> createLocalNote({
    required Account account,
    required String notebookId,
    required bool isMarkdown,
    String title = '',
    String content = '',
  }) => raw.transaction((txn) async {
    notebookId = await NotebookCreationJournal(
      raw,
      account.cacheKey,
    ).resolve(notebookId, transaction: txn);
    final now = DateTime.now().toUtc().toIso8601String();
    final note = Note(
      noteId: _objectId(),
      notebookId: notebookId,
      userId: account.userId,
      title: title,
      content: content,
      tags: const [],
      usn: 0,
      isMarkdown: isMarkdown,
      isStarred: false,
      isTrash: false,
      isDeleted: false,
      createdTime: now,
      updatedTime: now,
    );
    await _writeNote(
      account.cacheKey,
      note,
      isDirty: true,
      isNew: true,
      executor: txn,
    );
    return note;
  });

  /// A share's stable ID makes retry after a failed native acknowledgement
  /// idempotent. Never replace an already imported (possibly edited) note.
  Future<Note> importSharedText({
    required Account account,
    required String shareId,
    required String notebookId,
    required String title,
    required String content,
    AttachmentUpload? resource,
    bool resourceIsImage = false,
  }) => raw.transaction((txn) async {
    notebookId = await NotebookCreationJournal(
      raw,
      account.cacheKey,
    ).resolve(notebookId, transaction: txn);
    if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(shareId)) {
      throw const FormatException('invalidShareId');
    }
    final existing = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, shareId],
    );
    if (existing.isNotEmpty) return _noteFromRow(existing.single);
    final targets = await txn.query(
      'notebooks',
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, notebookId],
    );
    if (targets.isEmpty) throw StateError('目标笔记本已不存在，请返回重新选择');
    final now = DateTime.now().toUtc().toIso8601String();
    final note = Note.fromJson({
      'NoteId': shareId,
      'NotebookId': notebookId,
      'UserId': account.userId,
      'Title': title,
      'Content': content,
      'IsMarkdown': true,
      'CreatedTime': now,
      'UpdatedTime': now,
    });
    final batch = txn.batch();
    _insertNote(batch, account.cacheKey, note);
    batch.update(
      'notes',
      {'is_dirty': 1, 'local_is_new': 1},
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, shareId],
    );
    await batch.commit(noResult: true);
    if (resource != null) {
      await AttachmentOutbox(raw, account).stageInTransaction(
        txn,
        shareId,
        resource,
        kind: resourceIsImage ? 'image' : 'attachment',
      );
    }
    return note;
  });

  /// Copy the exact displayed snapshot, never silently dropping resource links.
  Future<Note> copyLocalNote({
    required Account account,
    required Note source,
    required String notebookId,
    required bool filesConfirmedEmpty,
    NoteBundle? bundle,
    String? expectedResources,
  }) => raw.transaction((txn) async {
    final rows = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND local_is_deleted = 0',
      whereArgs: [account.cacheKey, source.noteId],
    );
    if (rows.length != 1 ||
        source.userId != account.userId ||
        source.isTrash ||
        source.isDeleted ||
        _noteFingerprint(_noteFromRow(rows.single)) !=
            _noteFingerprint(source)) {
      throw StateError('笔记已变化或不可用，请重新打开后复制');
    }
    final targets = await txn.query(
      'notebooks',
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, notebookId],
    );
    if (targets.isEmpty) throw StateError('目标笔记本不存在，请刷新后重试');
    final files = await txn.query(
      'note_files',
      columns: ['file_id'],
      where: 'account_id = ? AND note_id = ?',
      whereArgs: [account.cacheKey, source.noteId],
      limit: 1,
    );
    if (bundle != null &&
        (!sameReviewedNote(bundle.note, source) ||
            expectedResources !=
                await resourceFingerprint(
                  account.cacheKey,
                  source.noteId,
                  executor: txn,
                ))) {
      throw StateError('笔记或资源已变化，请重新打开后重试。');
    }
    if (bundle == null &&
        ((source.usn > 0 && !filesConfirmedEmpty) ||
            files.isNotEmpty ||
            !canCopyConflictBody(
              source.content,
              isMarkdown: source.isMarkdown,
            ))) {
      throw StateError('暂不支持复制含链接、图片、附件或复杂 HTML 的笔记');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final copy = source.copyWith(
      noteId: _objectId(),
      notebookId: notebookId,
      title: '${source.title.isEmpty ? '无标题' : source.title}（副本）',
      usn: 0,
      createdTime: now,
      updatedTime: now,
    );
    final batch = txn.batch();
    _insertNote(batch, account.cacheKey, copy);
    batch.update(
      'notes',
      {'is_dirty': 1, 'local_is_new': 1},
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, copy.noteId],
    );
    await batch.commit(noResult: true);
    for (final resource in bundle?.resources ?? <BundledResource>[]) {
      await AttachmentOutbox(
        raw,
        account,
      ).stageBundle(txn, copy.noteId, resource);
    }
    return copy;
  });

  Future<String> resourceFingerprint(
    String accountId,
    String noteId, {
    DatabaseExecutor? executor,
  }) async => jsonEncode(
    await (executor ?? raw).rawQuery(
      """SELECT o.id, o.name, o.kind, o.state, o.remote_id, LENGTH(o.bytes) AS size, b.source_id, b.origin
      FROM attachment_outbox o LEFT JOIN resource_bindings b ON b.task_id = o.id
      WHERE o.account_id = ? AND o.note_id = ? ORDER BY o.id""",
      [accountId, noteId],
    ),
  );

  Future<Note> importBundle(
    Account account,
    String notebookId,
    NoteBundle bundle,
  ) => raw.transaction((txn) async {
    final target = await txn.query(
      'notebooks',
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, notebookId],
    );
    if (target.isEmpty) throw StateError('目标笔记本不存在，请刷新后重试');
    final now = DateTime.now().toUtc().toIso8601String();
    final note = bundle.note.copyWith(
      noteId: _objectId(),
      notebookId: notebookId,
      userId: account.userId,
      usn: 0,
      isTrash: false,
      isDeleted: false,
      createdTime: now,
      updatedTime: now,
    );
    final batch = txn.batch();
    _insertNote(batch, account.cacheKey, note);
    batch.update(
      'notes',
      {'is_dirty': 1, 'local_is_new': 1},
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, note.noteId],
    );
    await batch.commit(noResult: true);
    for (final resource in bundle.resources) {
      await AttachmentOutbox(
        raw,
        account,
      ).stageBundle(txn, note.noteId, resource);
    }
    return note;
  });

  Future<void> saveNoteTags(
    String accountId,
    String noteId,
    List<String> tags,
  ) => raw.transaction((txn) async {
    final normalized = tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    final rows = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND local_is_deleted = 0',
      whereArgs: [accountId, noteId],
    );
    if (rows.isEmpty) throw StateError('localNoteMissing');
    final current = _noteFromRow(rows.single);
    if (jsonEncode(current.tags) == jsonEncode(normalized)) return;
    // Also guard new notes: an add request may already be in flight.
    if (normalized.isEmpty) {
      throw const FormatException('当前服务端接口不支持清空全部标签，请至少保留一个标签');
    }
    await txn.update(
      'notes',
      {
        'tags_json': jsonEncode(normalized),
        'is_dirty': 1,
        'updated_time': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, noteId],
    );
  });

  Future<void> saveEditedText(
    String accountId,
    String noteId,
    String title,
    String content,
  ) => raw.transaction((txn) async {
    final rows = await txn.queryLargeValues(
      'notes',
      columns: ['title', 'content'],
      where: 'account_id = ? AND server_id = ? AND local_is_deleted = 0',
      whereArgs: [accountId, noteId],
    );
    if (rows.isEmpty) throw StateError('localNoteMissing');
    if (rows.single['title'] == title && rows.single['content'] == content) {
      return;
    }
    await txn.update(
      'notes',
      {
        'title': title,
        'content': content,
        'updated_time': DateTime.now().toUtc().toIso8601String(),
        'is_dirty': 1,
      },
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, noteId],
    );
  });

  Future<void> saveLocalNote(String accountId, Note note) =>
      raw.transaction((txn) async {
        final notebookId = await NotebookCreationJournal(
          raw,
          accountId,
        ).resolve(note.notebookId, transaction: txn);
        final changed = await txn.update(
          'notes',
          {
            'notebook_server_id': notebookId,
            'title': note.title,
            'content': note.content,
            'tags_json': jsonEncode(note.tags),
            'is_markdown': note.isMarkdown ? 1 : 0,
            'is_starred': note.isStarred ? 1 : 0,
            'is_trash': note.isTrash ? 1 : 0,
            'updated_time': note.updatedTime,
            'is_dirty': 1,
          },
          where: 'account_id = ? AND server_id = ? AND local_is_deleted = 0',
          whereArgs: [accountId, note.noteId],
        );
        if (changed != 1) throw StateError('localNoteMissing');
      });

  Future<void> deleteLocalTrash(String accountId, String noteId) async {
    final changed = await raw.update(
      'notes',
      {'local_is_deleted': 1, 'is_dirty': 1},
      where: 'account_id = ? AND server_id = ? AND is_trash = 1 AND local_is_deleted = 0',
      whereArgs: [accountId, noteId],
    );
    if (changed != 1) throw StateError('trashNoteMissing');
  }

  /// Stage a visual-editor image with a local reference that can be previewed
  /// and later replaced in place after the original is uploaded.
  Future<String> stageVisualImage(
    Account account,
    String noteId,
    Uint8List bytes,
  ) => raw.transaction((txn) async {
    final local = await txn.queryLargeValues(
      'notes',
      columns: ['is_markdown'],
      where: 'account_id = ? AND server_id = ? AND owner_server_id = ? AND is_trash = 0 AND local_is_deleted = 0',
      whereArgs: [account.cacheKey, noteId, account.userId],
      limit: 1,
    );
    if (local.length != 1 || local.single['is_markdown'] != 0) {
      throw StateError('只能为当前富文本笔记离线插入图片');
    }
    final sourceId = _objectId();
    final taskId = await AttachmentOutbox(raw, account).stageBundle(
      txn,
      noteId,
      BundledResource(
        file: AttachmentUpload(name: 'image.png', bytes: bytes),
        isImage: true,
        sourceId: sourceId,
        origin: account.server.origin,
      ),
    );
    await txn.update(
      'resource_bindings',
      {'local_placement': 1},
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
    return '/api2/file/getImage?fileId=$sourceId';
  });

  Future<Set<String>> pendingVisualSourceIds(
    String accountId,
    String noteId,
  ) async {
    final rows = await raw.rawQuery(
      '''SELECT b.source_id FROM resource_bindings b
      JOIN attachment_outbox o ON o.id = b.task_id
      WHERE o.account_id = ? AND o.note_id = ? AND o.kind = 'image'
      AND o.state != 'inserted' AND b.local_placement = 1''',
      [accountId, noteId],
    );
    return {for (final row in rows) row['source_id'] as String};
  }

  Future<bool> hasUnuploadedVisualPlacement(
    String accountId,
    String noteId,
  ) async {
    final rows = await raw.rawQuery(
      '''SELECT b.task_id FROM resource_bindings b JOIN attachment_outbox o ON o.id = b.task_id
      JOIN notes n ON n.account_id = o.account_id AND n.server_id = o.note_id
      WHERE o.account_id = ? AND o.note_id = ? AND o.kind = 'image'
      AND b.local_placement = 1 AND o.state != 'inserted'
      AND instr(n.content, b.source_id) > 0 LIMIT 1''',
      [accountId, noteId],
    );
    return rows.isNotEmpty;
  }

  Future<void> acknowledgeDeletion(String accountId, Note note) =>
      raw.transaction((txn) async {
        final changed = await txn.delete(
          'notes',
          where: 'account_id = ? AND server_id = ? AND local_is_deleted = 1 AND usn = ?',
          whereArgs: [accountId, note.noteId, note.usn],
        );
        if (changed != 1) throw StateError('localChangesDuringDeletion');
        await txn.delete(
          'note_histories',
          where: 'account_id = ? AND note_id = ?',
          whereArgs: [accountId, note.noteId],
        );
      });

  /// A stale permanent delete is cancelled when another device changed the
  /// note. Restore the reviewed remote version so deletion can be reconsidered
  /// with the current content, without silently discarding that device's work.
  Future<void> restoreConflictedDeletion(
    String accountId,
    Note local,
    Note remote,
  ) => raw.transaction((txn) async {
    if (!local.isDeleted ||
        remote.isDeleted ||
        remote.noteId != local.noteId ||
        remote.userId != local.userId ||
        remote.usn <= local.usn) {
      throw StateError('unresolvedNoteDeletion');
    }
    final rows = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND is_dirty = 1',
      whereArgs: [accountId, local.noteId],
      limit: 1,
    );
    if (rows.length != 1 ||
        _noteFingerprint(_noteFromRow(rows.single)) !=
            _noteFingerprint(local)) {
      throw StateError('localChangesDuringDeletion');
    }
    final batch = txn.batch();
    _insertNote(batch, accountId, remote);
    await batch.commit(noResult: true);
  });

  Future<void> _requireLiveNote(
    DatabaseExecutor db,
    String accountId,
    String noteId,
  ) async {
    final rows = await db.queryLargeValues(
      'notes',
      columns: ['server_id'],
      where: 'account_id = ? AND server_id = ? AND local_is_deleted = 0',
      whereArgs: [accountId, noteId],
    );
    if (rows.isEmpty) throw StateError('localNoteMissing');
  }

  Future<void> cacheHistories(
    String accountId,
    String noteId,
    List<NoteHistory> histories,
  ) => raw.transaction((txn) async {
    await _requireLiveNote(txn, accountId, noteId);
    final old = await txn.queryLargeValues(
      'note_histories',
      where: 'account_id = ? AND note_id = ?',
      whereArgs: [accountId, noteId],
    );
    final previous = {for (final row in old) row['history_id']: row};
    final ids = histories.map((history) => history.id).toSet();
    for (final row in old) {
      if (!ids.contains(row['history_id'])) {
        await txn.delete(
          'note_histories',
          where: 'account_id=? AND note_id=? AND history_id=?',
          whereArgs: [accountId, noteId, row['history_id']],
        );
      }
    }
    for (final history in histories) {
      final row = previous[history.id];
      final unchanged =
          row != null &&
          row['updated_time'] == history.updatedTime &&
          row['updated_user_id'] == history.updatedUserId &&
          row['is_markdown'] == (history.isMarkdown ? 1 : 0);
      final values = {
        'updated_time': history.updatedTime,
        'updated_user_id': history.updatedUserId,
        'is_markdown': history.isMarkdown ? 1 : 0,
        'content': unchanged ? row['content'] : null,
      };
      if (row == null) {
        await txn.insert('note_histories', {
          'account_id': accountId,
          'note_id': noteId,
          'history_id': history.id,
          ...values,
        });
      } else {
        if (!unchanged) {
          await txn.delete(
            'history_images',
            where: 'account_id=? AND note_id=? AND history_id=?',
            whereArgs: [accountId, noteId, history.id],
          );
        }
        await txn.update(
          'note_histories',
          values,
          where: 'account_id=? AND note_id=? AND history_id=?',
          whereArgs: [accountId, noteId, history.id],
        );
      }
    }
  });

  Future<List<NoteHistory>> cachedHistories(String accountId, String noteId) =>
      raw.transaction((txn) async {
        await _requireLiveNote(txn, accountId, noteId);
        final rows = await txn.queryLargeValues(
          'note_histories',
          where: 'account_id = ? AND note_id = ?',
          whereArgs: [accountId, noteId],
          orderBy: 'updated_time DESC, history_id',
        );
        return rows
            .map(
              (row) => NoteHistory(
                id: row['history_id'] as String,
                updatedTime: row['updated_time'] as String,
                updatedUserId: row['updated_user_id'] as String,
                isMarkdown: row['is_markdown'] == 1,
              ),
            )
            .toList();
      });

  Future<void> cacheHistoryContent(
    String accountId,
    String noteId,
    String historyId,
    String content,
  ) => raw.transaction((txn) async {
    await _requireLiveNote(txn, accountId, noteId);
    final previous = await txn.queryLargeValues(
      'note_histories',
      columns: ['content'],
      where: 'account_id = ? AND note_id = ? AND history_id = ?',
      whereArgs: [accountId, noteId, historyId],
    );
    if (previous.isNotEmpty && previous.single['content'] != content) {
      await txn.delete(
        'history_images',
        where: 'account_id = ? AND note_id = ? AND history_id = ?',
        whereArgs: [accountId, noteId, historyId],
      );
    }
    // The list may have been refreshed while this body was downloading.
    final count = await txn.update(
      'note_histories',
      {'content': content},
      where: 'account_id = ? AND note_id = ? AND history_id = ?',
      whereArgs: [accountId, noteId, historyId],
    );
    if (count != 1) throw StateError('historyNotListed');
  });

  Future<String> cachedHistoryContent(
    String accountId,
    String noteId,
    String historyId,
  ) => raw.transaction((txn) async {
    await _requireLiveNote(txn, accountId, noteId);
    final rows = await txn.queryLargeValues(
      'note_histories',
      columns: ['content'],
      where: 'account_id = ? AND note_id = ? AND history_id = ?',
      whereArgs: [accountId, noteId, historyId],
    );
    if (rows.isEmpty || rows.single['content'] == null) {
      throw StateError('此历史正文尚未缓存，请联网查看后再离线使用');
    }
    return rows.single['content'] as String;
  });

  Future<void> restoreHistoryContent(
    String accountId,
    String noteId,
    String content, {
    bool? isMarkdown,
  }) async {
    // Patch only the body of the latest cached row; the reader may hold an old
    // snapshot whose metadata or USN changed while the history was downloaded.
    final changed = await raw.update(
      'notes',
      {
        'content': content,
        'updated_time': DateTime.now().toUtc().toIso8601String(),
        'is_dirty': 1,
        if (isMarkdown != null) 'is_markdown': isMarkdown ? 1 : 0,
      },
      where: 'account_id = ? AND server_id = ? AND local_is_deleted = 0',
      whereArgs: [accountId, noteId],
    );
    if (changed != 1) throw StateError('localNoteMissing');
  }

  Future<Set<String>> pendingNoteIds(String accountId) async {
    final rows = await raw.queryLargeValues(
      'notes',
      columns: ['server_id'],
      where: 'account_id = ? AND is_dirty = 1',
      whereArgs: [accountId],
    );
    return rows.map((row) => row['server_id'] as String).toSet();
  }

  Future<List<Note>> dirtyNotes(String accountId) async {
    final rows = await raw.queryLargeValues(
      'notes',
      where: 'account_id = ? AND is_dirty = 1',
      whereArgs: [accountId],
      orderBy: 'created_time, server_id',
    );
    return rows.map(_noteFromRow).toList(growable: false);
  }

  /// Only accept a reviewed creation base; content, resources and pending work
  /// stay on the same note. No server write or account cursor advancement.
  Future<void> recoverNoteCreation(
    String accountId,
    NoteCreationReview review,
  ) => raw.transaction((txn) async {
    if (review.accountId != accountId ||
        review.local.usn != 0 ||
        review.remote.usn <= 0 ||
        review.local.noteId != review.remote.noteId ||
        review.local.userId != review.remote.userId ||
        review.remote.isDeleted ||
        review.remote.isTrash ||
        review.local.isDeleted ||
        review.local.isTrash) {
      throw StateError('noteCreationUnavailable');
    }
    final rows = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND is_dirty = 1 AND local_is_deleted = 0',
      whereArgs: [accountId, review.local.noteId],
    );
    if (rows.length != 1 ||
        !sameReviewedNote(_noteFromRow(rows.single), review.local)) {
      throw StateError('noteCreationLocalChanged');
    }
    // API2 cannot express clearing all tags. Do not promise an exact overwrite
    // that the existing server would silently fail to apply.
    if (review.local.tags.isEmpty && review.remote.tags.isNotEmpty) {
      throw StateError('noteCreationTags');
    }
    await txn.update(
      'notes',
      {'usn': review.remote.usn, 'local_is_new': 0},
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [accountId, review.local.noteId],
    );
    await txn.delete(
      'note_create_attempts',
      where: 'account_id = ? AND note_id = ?',
      whereArgs: [accountId, review.local.noteId],
    );
  });

  /// Atomically preserve a safe local body copy before accepting the remote note.
  /// Unsupported resource/deletion conflicts and concurrent edits remain dirty.
  Future<Note?> resolveNoteConflict(
    String accountId,
    Note local,
    Note remote, {
    required bool filesConfirmedEmpty,
    NoteBundle? bundle,
    Account? account,
    String? expectedResources,
  }) => raw.transaction((txn) async {
    if (remote.noteId != local.noteId ||
        remote.userId != local.userId ||
        remote.usn <= local.usn ||
        local.usn <= 0 ||
        local.isDeleted ||
        (!remote.isDeleted && remote.isTrash != local.isTrash)) {
      throw StateError('unresolvedNoteConflict');
    }
    final rows = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND is_dirty = 1',
      whereArgs: [accountId, local.noteId],
    );
    if (rows.length != 1 ||
        _noteFingerprint(_noteFromRow(rows.single)) !=
            _noteFingerprint(local)) {
      throw StateError('localChangesDuringConflict');
    }
    if (bundle != null &&
        (account == null ||
            account.cacheKey != accountId ||
            account.userId != local.userId ||
            !sameReviewedNote(bundle.note, local) ||
            expectedResources !=
                await resourceFingerprint(
                  accountId,
                  local.noteId,
                  executor: txn,
                ))) {
      throw StateError('localChangesDuringConflict');
    }
    Note? copy;
    if (remote.isDeleted ||
        remote.content != local.content ||
        remote.isMarkdown != local.isMarkdown) {
      // Without a verified bundle, reject resource-bearing bodies instead of
      // accepting a copy whose image or attachment bytes cannot be recovered.
      final files = await txn.query(
        'note_files',
        columns: ['file_id'],
        where: 'account_id = ? AND note_id = ?',
        whereArgs: [accountId, local.noteId],
        limit: 1,
      );
      if ((!remote.isDeleted && local.isTrash) ||
          (bundle == null &&
              (!filesConfirmedEmpty ||
                  !canCopyConflictBody(
                    local.content,
                    isMarkdown: local.isMarkdown,
                  ) ||
                  !canCopyConflictBody(
                    remote.content,
                    isMarkdown: remote.isMarkdown,
                  ) ||
                  files.isNotEmpty))) {
        throw StateError('unresolvedNoteConflict');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      copy = local.copyWith(
        noteId: _objectId(),
        title: '${local.title}（本地冲突副本）',
        usn: 0,
        isTrash: false,
        createdTime: now,
        updatedTime: now,
      );
    }
    final batch = txn.batch();
    if (copy != null) {
      _insertNote(batch, accountId, copy);
      batch.update(
        'notes',
        {'is_dirty': 1, 'local_is_new': 1},
        where: 'account_id = ? AND server_id = ?',
        whereArgs: [accountId, copy.noteId],
      );
    }
    if (remote.isDeleted) {
      batch.delete(
        'note_histories',
        where: 'account_id = ? AND note_id = ?',
        whereArgs: [accountId, local.noteId],
      );
      batch.delete(
        'notes',
        where: 'account_id = ? AND server_id = ?',
        whereArgs: [accountId, local.noteId],
      );
    } else {
      _insertNote(batch, accountId, remote);
    }
    await batch.commit(noResult: true);
    if (copy != null && bundle != null) {
      for (final resource in bundle.resources) {
        await AttachmentOutbox(
          raw,
          account!,
        ).stageBundle(txn, copy.noteId, resource);
      }
    }
    // Do not advance the account cursor: other remote changes are still unread.
    return copy;
  });

  static String _noteFingerprint(Note note) => jsonEncode([
    note.noteId,
    note.userId,
    note.notebookId,
    note.title,
    note.content,
    note.tags,
    note.usn,
    note.isMarkdown,
    note.isStarred,
    note.isTrash,
    note.isDeleted,
    note.createdTime,
    note.updatedTime,
  ]);

  Future<void> markNoteUploaded(
    String accountId,
    Note local,
    Note remote,
  ) async {
    if (remote.noteId != local.noteId || remote.usn <= 0) {
      throw StateError('invalidUploadResponse');
    }
    await raw.transaction((txn) async {
      final rows = await txn.queryLargeValues(
        'notes',
        where: 'account_id = ? AND server_id = ?',
        whereArgs: [accountId, local.noteId],
      );
      if (rows.isEmpty) throw StateError('localNoteMissing');
      final current = _noteFromRow(rows.single);
      final unchanged =
          current.isDeleted == local.isDeleted &&
          current.title == local.title &&
          current.content == local.content &&
          current.notebookId == local.notebookId &&
          jsonEncode(current.tags) == jsonEncode(local.tags) &&
          current.isStarred == local.isStarred &&
          current.isTrash == local.isTrash &&
          current.isMarkdown == local.isMarkdown &&
          current.updatedTime == local.updatedTime;
      await txn.update(
        'notes',
        {
          'usn': remote.usn,
          'local_is_new': 0,
          'is_dirty': unchanged ? 0 : 1,
          if (unchanged && remote.updatedTime.isNotEmpty)
            'updated_time': remote.updatedTime,
        },
        where: 'account_id = ? AND server_id = ?',
        whereArgs: [accountId, local.noteId],
      );
      if (local.usn == 0) {
        await txn.delete(
          'note_create_attempts',
          where: 'account_id = ? AND note_id = ?',
          whereArgs: [accountId, local.noteId],
        );
      }
    });
  }

  Future<void> _writeNote(
    String accountId,
    Note note, {
    required bool isDirty,
    required bool isNew,
    DatabaseExecutor? executor,
  }) => (executor ?? raw).insert('notes', {
    'account_id': accountId,
    'server_id': note.noteId,
    'notebook_server_id': note.notebookId,
    'owner_server_id': note.userId,
    'title': note.title,
    'content': note.content,
    'tags_json': jsonEncode(note.tags),
    'usn': note.usn,
    'is_markdown': note.isMarkdown ? 1 : 0,
    'is_starred': note.isStarred ? 1 : 0,
    'is_trash': note.isTrash ? 1 : 0,
    'created_time': note.createdTime,
    'updated_time': note.updatedTime,
    'is_dirty': isDirty ? 1 : 0,
    'local_is_new': isNew ? 1 : 0,
    'local_is_deleted': 0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static void _insertNote(Batch batch, String accountId, Note note) {
    batch.insert('notes', {
      'account_id': accountId,
      'server_id': note.noteId,
      'notebook_server_id': note.notebookId,
      'owner_server_id': note.userId,
      'title': note.title,
      'content': note.content,
      'tags_json': jsonEncode(note.tags),
      'usn': note.usn,
      'is_markdown': note.isMarkdown ? 1 : 0,
      'is_starred': note.isStarred ? 1 : 0,
      'is_trash': note.isTrash ? 1 : 0,
      'created_time': note.createdTime,
      'updated_time': note.updatedTime,
      'is_dirty': 0,
      'local_is_new': 0,
      'local_is_deleted': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deactivate(String accountId) async {
    await raw.update(
      'accounts',
      {'is_active': 0},
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  static Note _noteFromRow(Map<String, Object?> row) => Note(
    noteId: row['server_id']! as String,
    notebookId: row['notebook_server_id']! as String,
    userId: row['owner_server_id']! as String,
    title: row['title']! as String,
    content: row['content']! as String,
    tags: (jsonDecode(row['tags_json']! as String) as List)
        .map((item) => item.toString())
        .toList(growable: false),
    usn: row['usn']! as int,
    isMarkdown: row['is_markdown'] == 1,
    isStarred: row['is_starred'] == 1,
    isTrash: row['is_trash'] == 1,
    isDeleted: row['local_is_deleted'] == 1,
    createdTime: row['created_time']! as String,
    updatedTime: row['updated_time']! as String,
  );

  static int _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  static String _objectId() {
    final random = Random.secure();
    return List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  // Local preferences intentionally outlive account snapshot REPLACE. They do
  // not participate in synchronization or cascade with downloaded cache rows.
  static const _cachePreferencesSchema =
      '''CREATE TABLE IF NOT EXISTS account_cache_preferences (
        account_id TEXT PRIMARY KEY,
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        auto_sync INTEGER NOT NULL DEFAULT 0 CHECK (auto_sync IN (0, 1))
      )''';

  static const _sortPreferencesSchema =
      """CREATE TABLE IF NOT EXISTS account_note_sort (
        account_id TEXT PRIMARY KEY,
        note_sort TEXT NOT NULL CHECK (note_sort IN (
          'updatedDescending', 'updatedAscending', 'createdDescending', 'createdAscending',
          'titleAscending', 'titleDescending'))
      )""";

  static const _preferencesSchema =
      '''CREATE TABLE IF NOT EXISTS account_preferences (
    account_id TEXT PRIMARY KEY,
    default_editor TEXT NOT NULL CHECK (default_editor IN ('html', 'markdown'))
  )''';

  static const _historySchema = '''CREATE TABLE note_histories (
    account_id TEXT NOT NULL,
    note_id TEXT NOT NULL,
    history_id TEXT NOT NULL,
    updated_time TEXT NOT NULL,
    updated_user_id TEXT NOT NULL,
    content TEXT,
    is_markdown INTEGER NOT NULL DEFAULT 0 CHECK (is_markdown IN (0, 1)),
    PRIMARY KEY (account_id, note_id, history_id),
    FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
  )''';

  static const _avatarSchema = '''CREATE TABLE account_avatars (
    account_id TEXT PRIMARY KEY,
    bytes BLOB NOT NULL,
    FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
  )''';

  static const _sharedSchema = '''CREATE TABLE shared_notes (
    account_id TEXT NOT NULL, note_id TEXT NOT NULL, owner_id TEXT NOT NULL,
    version TEXT NOT NULL, metadata TEXT NOT NULL, content TEXT,
    PRIMARY KEY (account_id, note_id),
    FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
  )''';

  static const _fileCacheSchema = '''CREATE TABLE note_files (
    account_id TEXT NOT NULL, note_id TEXT NOT NULL, file_id TEXT NOT NULL,
    title TEXT NOT NULL, type TEXT NOT NULL, is_attachment INTEGER NOT NULL,
    generation TEXT NOT NULL, bytes BLOB, cached_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, note_id, file_id),
    FOREIGN KEY (account_id, note_id) REFERENCES notes(account_id, server_id) ON DELETE CASCADE
  )''';

  static const _schema = <String>[
    '''CREATE TABLE accounts (
      account_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      server TEXT NOT NULL,
      username TEXT NOT NULL,
      email TEXT NOT NULL,
      logo TEXT NOT NULL DEFAULT '',
      api_version TEXT NOT NULL DEFAULT '',
      last_sync_usn INTEGER NOT NULL DEFAULT 0,
      is_active INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE notebooks (
      account_id TEXT NOT NULL,
      server_id TEXT NOT NULL,
      parent_server_id TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL,
      sequence INTEGER NOT NULL DEFAULT 0,
      usn INTEGER NOT NULL DEFAULT 0,
      number_notes INTEGER NOT NULL DEFAULT 0,
      is_dirty INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (account_id, server_id),
      FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    )''',
    '''CREATE TABLE notes (
      account_id TEXT NOT NULL,
      server_id TEXT NOT NULL,
      notebook_server_id TEXT NOT NULL DEFAULT '',
      owner_server_id TEXT NOT NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      tags_json TEXT NOT NULL DEFAULT '[]',
      usn INTEGER NOT NULL DEFAULT 0,
      is_markdown INTEGER NOT NULL DEFAULT 0,
      is_starred INTEGER NOT NULL DEFAULT 0,
      is_trash INTEGER NOT NULL DEFAULT 0,
      created_time TEXT NOT NULL DEFAULT '',
      updated_time TEXT NOT NULL DEFAULT '',
      is_dirty INTEGER NOT NULL DEFAULT 0,
      local_is_new INTEGER NOT NULL DEFAULT 0,
      local_is_deleted INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (account_id, server_id),
      FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    )''',
    '''CREATE TABLE tags (
      account_id TEXT NOT NULL,
      name TEXT NOT NULL,
      usn INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (account_id, name),
      FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    )''',
    'CREATE INDEX notebook_parent_idx ON notebooks(account_id, parent_server_id)',
    'CREATE INDEX note_notebook_idx ON notes(account_id, notebook_server_id)',
    'CREATE INDEX note_dirty_idx ON notes(account_id, is_dirty)',
    _historySchema,
    _avatarSchema,
    _sharedSchema,
    _fileCacheSchema,
    _preferencesSchema,
    _sortPreferencesSchema,
    _cachePreferencesSchema,
    ...FileDownloadJournal.schema,
    AttachmentOutbox.schema,
    AttachmentOutbox.bindingSchema,
    NotebookCreationJournal.schema,
    NoteCreationJournal.schema,
    HistoryImageCache.schema,
    SharedFileCache.schema,
    _appPreferencesSchema,
  ];
}
