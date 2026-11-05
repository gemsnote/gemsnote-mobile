import 'large_values.dart';

import '../../domain/models/note_bundle.dart';

import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../domain/models/account.dart';
import '../../domain/models/attachment_upload.dart';
import '../../services/note_image_picker.dart';

class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.noteId,
    required this.name,
    required this.size,
    required this.state,
    required this.remoteId,
    this.kind = 'attachment',
  });
  final String id, noteId, name, state, remoteId;
  final String kind;
  bool get isImage => kind == 'image';
  final int size;
  String get statusLabel => switch (state) {
    'pending' => '待上传',
    'uncertain' => '上传结果待确认',
    'uploaded' => '已上传，本地副本保留',
    'inserted' => '已插入本地正文',
    'cleaned' => '服务端图片已清理，本地原件保留',
    'cleaning' => '图片清理结果待确认，本地原件保留',
    _ => '状态异常，请导出保留',
  };
}

/// User-owned originals, never part of the evictable download cache. Deliberately
/// no cascading FK: replacing a server snapshot must not delete unsent bytes.
class AttachmentOutbox {
  AttachmentOutbox(this.database, this.account);
  final Database database;
  final Account account;
  static const maxBytes = 64 * 1024 * 1024;
  static const maxItems = 64;
  static const schema = '''CREATE TABLE IF NOT EXISTS attachment_outbox (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    note_id TEXT NOT NULL,
    name TEXT NOT NULL,
    bytes BLOB NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending',
    remote_id TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL DEFAULT 'attachment',
    created_at INTEGER NOT NULL
  )''';

  static const bindingSchema = """CREATE TABLE IF NOT EXISTS resource_bindings (
    task_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, origin TEXT NOT NULL,
    local_placement INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(task_id) REFERENCES attachment_outbox(id) ON DELETE CASCADE
  )""";

  Future<String> stageBundle(
    DatabaseExecutor txn,
    String noteId,
    BundledResource resource,
  ) async {
    final id = await stageInTransaction(
      txn,
      noteId,
      resource.file,
      kind: resource.isImage ? 'image' : 'attachment',
    );
    if (resource.sourceId.isNotEmpty) {
      await txn.insert('resource_bindings', {
        'task_id': id,
        'source_id': resource.sourceId,
        'origin': resource.origin,
      });
    }
    return id;
  }

  Future<List<BundledResource>> bundledResources(String noteId) async {
    final rows = await database.rawQuery(
      """SELECT o.*, b.source_id, b.origin FROM attachment_outbox o
      LEFT JOIN resource_bindings b ON b.task_id = o.id
      WHERE o.account_id = ? AND o.note_id = ? ORDER BY o.created_at, o.id""",
      [account.cacheKey, noteId],
    );
    return rows
        .map(
          (r) => BundledResource(
            file: AttachmentUpload(
              name: r['name'] as String,
              bytes: Uint8List.fromList(r['bytes'] as List<int>),
            ),
            isImage: r['kind'] == 'image',
            sourceId:
                (r['state'] == 'inserted' ||
                        (r['kind'] == 'attachment' &&
                            r['state'] == 'uploaded' &&
                            r['source_id'] == null)) &&
                    (r['remote_id'] as String).isNotEmpty
                ? r['remote_id'] as String
                : r['source_id'] as String? ?? '',
            origin:
                (r['state'] == 'inserted' ||
                        (r['kind'] == 'attachment' &&
                            r['state'] == 'uploaded' &&
                            r['source_id'] == null)) &&
                    (r['remote_id'] as String).isNotEmpty
                ? account.server.origin
                : r['origin'] as String? ?? '',
          ),
        )
        .toList();
  }

  Future<bool> hasBinding(String id) async => (await database.rawQuery(
    'SELECT b.task_id FROM resource_bindings b JOIN attachment_outbox o ON o.id = b.task_id WHERE o.account_id = ? AND o.id = ?',
    [account.cacheKey, id],
  )).isNotEmpty;

  Future<bool> isLocalPlacement(String id) async => (await database.rawQuery(
    '''SELECT b.task_id FROM resource_bindings b JOIN attachment_outbox o ON o.id = b.task_id
    WHERE o.account_id = ? AND o.id = ? AND b.local_placement = 1''',
    [account.cacheKey, id],
  )).isNotEmpty;

  Future<Uint8List?> boundImage(String noteId, Uri uri) async {
    final rows = await database.rawQuery(
      """SELECT o.id, b.source_id, b.origin FROM resource_bindings b
      JOIN attachment_outbox o ON o.id = b.task_id JOIN notes n ON n.account_id = o.account_id AND n.server_id = o.note_id
      WHERE o.account_id = ? AND o.note_id = ? AND o.kind = 'image' AND o.state != 'inserted'
      AND n.owner_server_id = ? AND n.local_is_deleted = 0 AND n.is_trash = 0""",
      [account.cacheKey, noteId, account.userId],
    );
    for (final row in rows) {
      final descriptor = BundledResource(
        file: AttachmentUpload(name: 'image', bytes: Uint8List(1)),
        isImage: true,
        sourceId: row['source_id'] as String,
        origin: row['origin'] as String,
      );
      if (matchesBundledResource(uri, descriptor)) {
        return (await file(row['id'] as String)).bytes;
      }
    }
    return null;
  }

  Future<String> stage(String noteId, AttachmentUpload file) =>
      _stage(noteId, file, 'attachment');
  Future<String> stageImage(String noteId, NoteImageUpload image) => _stage(
    noteId,
    AttachmentUpload(name: 'image.png', bytes: image.bytes),
    'image',
  );
  Future<String> _stage(String noteId, AttachmentUpload file, String kind) =>
      database.transaction(
        (txn) => stageInTransaction(txn, noteId, file, kind: kind),
      );

  Future<String> stageInTransaction(
    DatabaseExecutor txn,
    String noteId,
    AttachmentUpload file, {
    String kind = 'attachment',
  }) async {
    if (!{'attachment', 'image'}.contains(kind)) {
      throw StateError('invalidResourceKind');
    }
    final owner = await txn.queryLargeValues(
      'notes',
      columns: ['server_id'],
      where: 'account_id = ? AND server_id = ? AND owner_server_id = ? AND is_trash = 0 AND local_is_deleted = 0',
      whereArgs: [account.cacheKey, noteId, account.userId],
    );
    if (owner.isEmpty) throw StateError('不能向不存在或回收站中的笔记添加附件');
    final usage = (await txn.rawQuery(
      'SELECT COUNT(*) AS count, COALESCE(SUM(LENGTH(bytes)), 0) AS size FROM attachment_outbox',
    )).single;
    if ((usage['count'] as int) >= maxItems ||
        (usage['size'] as int) + file.bytes.length > maxBytes) {
      throw StateError('本地附件暂存已满（最多 64 个、合计 64 MiB），请先处理或导出已有附件');
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await txn.insert('attachment_outbox', {
      'id': id,
      'account_id': account.cacheKey,
      'note_id': noteId,
      'name': file.name,
      'kind': kind,
      'bytes': file.bytes,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<List<PendingAttachment>> list({String? noteId}) async {
    final rows = await database.query(
      'attachment_outbox',
      columns: [
        'id',
        'note_id',
        'name',
        'LENGTH(bytes) AS size',
        'state',
        'remote_id',
        'kind',
      ],
      where: 'account_id = ?${noteId == null ? '' : ' AND note_id = ?'}',
      whereArgs: [account.cacheKey, ?noteId],
      orderBy: 'created_at, id',
    );
    return rows
        .map(
          (r) => PendingAttachment(
            id: r['id'] as String,
            noteId: r['note_id'] as String,
            name: r['name'] as String,
            size: r['size'] as int,
            state: r['state'] as String,
            remoteId: r['remote_id'] as String,
            kind: r['kind'] as String,
          ),
        )
        .toList();
  }

  Future<AttachmentUpload> file(String id) async {
    final rows = await database.query(
      'attachment_outbox',
      where: 'account_id = ? AND id = ?',
      whereArgs: [account.cacheKey, id],
    );
    if (rows.isEmpty) throw StateError('本地附件不存在');
    return AttachmentUpload(
      name: rows.single['name'] as String,
      bytes: Uint8List.fromList(rows.single['bytes'] as List<int>),
    );
  }

  Future<void> markSending(String id) =>
      _transition(id, 'pending', 'uncertain');
  Future<void> confirm(String id, String remoteId) async {
    if (!RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(remoteId)) {
      throw StateError('invalidAttachmentId');
    }
    await _transition(id, 'uncertain', 'uploaded', remoteId: remoteId);
  }

  /// Only after the user explicitly checks the server and accepts duplication risk.
  Future<void> retryUncertain(String id) =>
      _transition(id, 'uncertain', 'pending');

  Future<void> beginImageCleanup(String id) =>
      _transition(id, 'uploaded', 'cleaning');
  Future<void> cancelImageCleanup(String id) =>
      _transition(id, 'cleaning', 'uploaded');
  Future<void> markImageCleaned(String id) =>
      _transition(id, 'cleaning', 'cleaned');

  Future<void> _transition(
    String id,
    String from,
    String to, {
    String? remoteId,
  }) async {
    final count = await database.update(
      'attachment_outbox',
      {'state': to, 'remote_id': ?remoteId},
      where: 'account_id = ? AND id = ? AND state = ?',
      whereArgs: [account.cacheKey, id, from],
    );
    if (count != 1) throw StateError('附件任务状态已变化，请刷新');
  }

  Future<void> remove(String id) async {
    await database.delete(
      'attachment_outbox',
      where: 'account_id = ? AND id = ?',
      whereArgs: [account.cacheKey, id],
    );
  }

  /// Body insertion and acknowledgement are one transaction. Retry after a
  /// process crash cannot append a second image or overwrite intervening edits.
  Future<void> insertImage(String id) => database.transaction((txn) async {
    final tasks = await txn.query(
      'attachment_outbox',
      where: 'account_id = ? AND id = ?',
      whereArgs: [account.cacheKey, id],
    );
    if (tasks.isEmpty) throw StateError('本地图片任务不存在');
    final task = tasks.single;
    if (task['state'] == 'inserted') return;
    final remoteId = task['remote_id'] as String;
    if (task['state'] != 'uploaded' ||
        !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(remoteId)) {
      throw StateError('图片上传结果尚未确认');
    }
    final notes = await txn.queryLargeValues(
      'notes',
      where: 'account_id = ? AND server_id = ? AND owner_server_id = ? AND is_trash = 0 AND local_is_deleted = 0',
      whereArgs: [account.cacheKey, task['note_id'], account.userId],
    );
    if (notes.isEmpty) throw StateError('原笔记不存在或已在回收站，图片原件仍保留');
    final note = notes.single;
    final bindings = await txn.query(
      'resource_bindings',
      where: 'task_id = ?',
      whereArgs: [id],
    );
    final reference = '/api2/file/getImage?fileId=$remoteId';
    final markup = note['is_markdown'] == 1
        ? '\n![]($reference)\n'
        : '\n<img src="$reference" alt="">\n';
    final content = bindings.isNotEmpty
        ? rebindResource(
            note['content'] as String,
            BundledResource(
              file: AttachmentUpload(
                name: task['name'] as String,
                bytes: Uint8List.fromList(task['bytes'] as List<int>),
              ),
              isImage: task['kind'] == 'image',
              sourceId: bindings.single['source_id'] as String,
              origin: bindings.single['origin'] as String,
            ),
            remoteId,
          )
        : task['kind'] == 'image'
        ? '${note['content']}$markup'
        : note['content'] as String;
    await txn.update(
      'notes',
      {
        'content': content,
        'is_dirty': 1,
        'updated_time': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'account_id = ? AND server_id = ?',
      whereArgs: [account.cacheKey, task['note_id']],
    );
    await txn.update(
      'attachment_outbox',
      {'state': 'inserted'},
      where: 'account_id = ? AND id = ?',
      whereArgs: [account.cacheKey, id],
    );
  });

  Future<Uint8List?> insertedImage(String noteId, String fileId) async {
    final rows = await database.rawQuery(
      '''SELECT o.bytes FROM attachment_outbox o JOIN notes n ON n.account_id = o.account_id AND n.server_id = o.note_id
      WHERE o.account_id = ? AND o.note_id = ? AND o.remote_id = ? AND o.kind = 'image' AND o.state = 'inserted'
      AND n.owner_server_id = ? AND n.is_trash = 0 AND n.local_is_deleted = 0 LIMIT 1''',
      [account.cacheKey, noteId, fileId, account.userId],
    );
    return rows.isEmpty
        ? null
        : Uint8List.fromList(rows.single['bytes'] as List<int>);
  }
}
