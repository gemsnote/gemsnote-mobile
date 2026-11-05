import 'large_values.dart';

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../domain/models/note.dart';

class NoteCreationAttempt {
  const NoteCreationAttempt(this.note, this.replayed);
  final Note note;
  final bool replayed;
}

/// A stable ClientNoteId is not enough: retries must also retain the exact first
/// payload, so later local edits cannot be acknowledged by an old response.
class NoteCreationJournal {
  NoteCreationJournal(this.database, this.accountId);
  final Database database;
  final String accountId;
  static const schema = '''CREATE TABLE IF NOT EXISTS note_create_attempts (
    account_id TEXT NOT NULL, note_id TEXT NOT NULL, payload TEXT NOT NULL,
    PRIMARY KEY(account_id, note_id),
    FOREIGN KEY(account_id, note_id) REFERENCES notes(account_id, server_id) ON DELETE CASCADE
  )''';

  Future<NoteCreationAttempt> prepare(Note local) => database.transaction((
    txn,
  ) async {
    final current = await txn.queryLargeValues(
      'notes',
      columns: ['owner_server_id'],
      where: 'account_id = ? AND server_id = ? AND usn = 0 AND is_dirty = 1 AND local_is_deleted = 0',
      whereArgs: [accountId, local.noteId],
    );
    if (current.isEmpty || current.single['owner_server_id'] != local.userId) {
      throw StateError('localChangesDuringCreation');
    }
    final existing = await txn.queryLargeValues(
      'note_create_attempts',
      where: 'account_id = ? AND note_id = ?',
      whereArgs: [accountId, local.noteId],
    );
    if (existing.isNotEmpty) {
      final note = Note.fromJson(
        Map<String, Object?>.from(
          jsonDecode(existing.single['payload'] as String) as Map,
        ),
      );
      if (note.noteId != local.noteId ||
          note.userId != local.userId ||
          note.usn != 0) {
        throw StateError('invalidCreationSnapshot');
      }
      return NoteCreationAttempt(note, true);
    }
    // API2 AddNote initializes IsTrash=false. A pending trash transition is
    // uploaded as an update after the create is acknowledged.
    final note = local.copyWith(isTrash: false);
    await txn.insert('note_create_attempts', {
      'account_id': accountId,
      'note_id': note.noteId,
      'payload': jsonEncode({
        'NoteId': note.noteId,
        'NotebookId': note.notebookId,
        'UserId': note.userId,
        'Title': note.title,
        'Content': note.content,
        'Tags': note.tags,
        'Usn': 0,
        'IsMarkdown': note.isMarkdown,
        'IsStar': note.isStarred,
        'IsTrash': false,
        'IsDeleted': false,
        'CreatedTime': note.createdTime,
        'UpdatedTime': note.updatedTime,
      }),
    });
    return NoteCreationAttempt(note, false);
  });

  static bool matches(Note requested, Note observed) =>
      requested.noteId == observed.noteId &&
      requested.userId == observed.userId &&
      requested.notebookId == observed.notebookId &&
      requested.title == observed.title &&
      requested.content == observed.content &&
      requested.isMarkdown == observed.isMarkdown &&
      requested.isStarred == observed.isStarred &&
      requested.isTrash == observed.isTrash &&
      !observed.isDeleted &&
      jsonEncode(requested.tags) == jsonEncode(observed.tags);
}
