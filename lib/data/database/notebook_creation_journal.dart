import 'dart:math';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../domain/models/notebook.dart';

class NotebookCreationJournal {
  NotebookCreationJournal(this.database, this.accountId);
  final Database database;
  final String accountId;
  static const schema = '''CREATE TABLE IF NOT EXISTS notebook_creations (
    account_id TEXT NOT NULL, local_id TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending', remote_id TEXT NOT NULL DEFAULT '',
    request_json TEXT NOT NULL DEFAULT '',
    PRIMARY KEY(account_id, local_id),
    FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
  )''';

  static Notebook _book(Map<String, Object?> row) => Notebook(
    notebookId: row['server_id'] as String,
    parentNotebookId: row['parent_server_id'] as String,
    title: row['title'] as String,
    sequence: row['sequence'] as int,
    usn: row['usn'] as int,
    numberNotes: row['number_notes'] as int,
    isDeleted: false,
    isDirty: row['is_dirty'] == 1,
  );

  Future<String> resolve(String id, {DatabaseExecutor? transaction}) async {
    final txn = transaction ?? database;
    final seen = <String>{};
    while (id.isNotEmpty) {
      if (!seen.add(id)) throw StateError('notebookMappingCycle');
      final rows = await txn.query(
        'notebook_creations',
        where: "account_id = ? AND local_id = ? AND state = 'complete'",
        whereArgs: [accountId, id],
      );
      if (rows.isEmpty || rows.single['remote_id'] == id) break;
      id = rows.single['remote_id'] as String;
    }
    return id;
  }

  Future<String?> state(String id, {DatabaseExecutor? transaction}) async {
    final rows = await (transaction ?? database).query(
      'notebook_creations',
      columns: ['state'],
      where: 'account_id = ? AND local_id = ?',
      whereArgs: [accountId, id],
    );
    return rows.isEmpty ? null : rows.single['state'] as String;
  }

  Future<Notebook> create(String title, String parentId) =>
      database.transaction((txn) async {
        title = title.trim();
        if (title.isEmpty) throw const FormatException('请输入笔记本名称');
        parentId = await resolve(parentId, transaction: txn);
        if (parentId.isNotEmpty &&
            (await txn.query(
              'notebooks',
              where: 'account_id = ? AND server_id = ?',
              whereArgs: [accountId, parentId],
            )).isEmpty) {
          throw StateError('父笔记本已不存在');
        }
        final random = Random.secure();
        final id = List.generate(
          12,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final row = <String, Object?>{
          'account_id': accountId,
          'server_id': id,
          'parent_server_id': parentId,
          'title': title,
          'sequence': 0,
          'usn': 0,
          'number_notes': 0,
          'is_dirty': 1,
        };
        await txn.insert('notebooks', row);
        await txn.insert('notebook_creations', {
          'account_id': accountId,
          'local_id': id,
        });
        return _book(row);
      });

  Future<Notebook> begin(String id, {bool idempotent = false}) =>
      database.transaction((txn) async {
        final tasks = await txn.query(
          'notebook_creations',
          where: 'account_id = ? AND local_id = ?',
          whereArgs: [accountId, id],
        );
        if (tasks.isNotEmpty &&
            tasks.single['state'] == 'uncertain' &&
            idempotent &&
            tasks.single['request_json'] != '') {
          final request = jsonDecode(
            tasks.single['request_json'] as String,
          ) as Map<String, dynamic>;
          return Notebook(
            notebookId: id,
            parentNotebookId: request['parent'] as String,
            title: request['title'] as String,
            sequence: request['seq'] as int,
            usn: 0,
            numberNotes: 0,
            isDeleted: false,
          );
        }
        if (await state(id, transaction: txn) != 'pending') {
          throw StateError('笔记本创建结果待确认，请从笔记本菜单核实恢复，不会自动重复创建');
        }
        final rows = await txn.query(
          'notebooks',
          where: 'account_id = ? AND server_id = ? AND usn = 0',
          whereArgs: [accountId, id],
        );
        if (rows.isEmpty) throw StateError('localNotebookMissing');
        final book = _book(rows.single);
        if (book.parentNotebookId.isNotEmpty) {
          final parents = await txn.query(
            'notebooks',
            where: 'account_id = ? AND server_id = ? AND usn > 0',
            whereArgs: [accountId, book.parentNotebookId],
          );
          if (parents.isEmpty) throw StateError('请先同步父笔记本');
        }
        await txn.update(
          'notebook_creations',
          {
            'state': 'uncertain',
            'request_json': idempotent
                ? jsonEncode({
                    'title': book.title,
                    'parent': book.parentNotebookId,
                    'seq': book.sequence,
                  })
                : '',
          },
          where: 'account_id = ? AND local_id = ?',
          whereArgs: [accountId, id],
        );
        return book;
      });

  Future<void> retry(String id) async {
    final changed = await database.update(
      'notebook_creations',
      {'state': 'pending'},
      where: "account_id = ? AND local_id = ? AND state = 'uncertain'",
      whereArgs: [accountId, id],
    );
    if (changed != 1) throw StateError('笔记本任务状态已变化，请刷新');
  }

  Future<void> confirm(Notebook local, Notebook remote) =>
      database.transaction((txn) async {
        if (await state(local.notebookId, transaction: txn) != 'uncertain' ||
            remote.usn <= 0 ||
            remote.isDeleted ||
            !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(remote.notebookId) ||
            remote.notebookId == remote.parentNotebookId ||
            remote.title != local.title ||
            remote.parentNotebookId != local.parentNotebookId ||
            remote.sequence != local.sequence) {
          throw StateError('笔记本创建结果与本地内容不一致，请核实恢复');
        }
        final rows = await txn.query(
          'notebooks',
          where: 'account_id = ? AND server_id = ? AND usn = 0',
          whereArgs: [accountId, local.notebookId],
        );
        if (rows.isEmpty) throw StateError('localNotebookMissing');
        final current = _book(rows.single);
        if (current.title != local.title ||
            current.parentNotebookId != local.parentNotebookId ||
            current.sequence != local.sequence) {
          throw StateError('localChangesDuringNotebookCreate');
        }
        if (remote.notebookId != local.notebookId) {
          final targets = await txn.query(
            'notebooks',
            where: 'account_id = ? AND server_id = ?',
            whereArgs: [accountId, remote.notebookId],
          );
          if (targets.isNotEmpty &&
              (targets.single['is_dirty'] == 1 ||
                  (targets.single['usn'] as int) > remote.usn)) {
            throw StateError('目标笔记本已有未同步修改或更新版本，请先处理');
          }
          await txn.delete(
            'notebooks',
            where: 'account_id = ? AND server_id = ?',
            whereArgs: [accountId, local.notebookId],
          );
        }
        await txn.insert('notebooks', {
          'account_id': accountId,
          'server_id': remote.notebookId,
          'parent_server_id': remote.parentNotebookId,
          'title': remote.title,
          'sequence': remote.sequence,
          'usn': remote.usn,
          'number_notes': remote.numberNotes,
          'is_dirty': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.update(
          'notebooks',
          {'parent_server_id': remote.notebookId},
          where: 'account_id = ? AND parent_server_id = ?',
          whereArgs: [accountId, local.notebookId],
        );
        await txn.update(
          'notes',
          {'notebook_server_id': remote.notebookId},
          where: 'account_id = ? AND notebook_server_id = ?',
          whereArgs: [accountId, local.notebookId],
        );
        await txn.update(
          'notebook_creations',
          {'state': 'complete', 'remote_id': remote.notebookId},
          where: 'account_id = ? AND local_id = ?',
          whereArgs: [accountId, local.notebookId],
        );
      });
}
