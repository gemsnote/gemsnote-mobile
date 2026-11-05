import 'dart:convert';

import 'note.dart';

class NoteCreationReview {
  const NoteCreationReview({
    required this.accountId,
    required this.local,
    required this.remote,
  });
  final String accountId;
  final Note local, remote;
}

bool sameReviewedNote(Note a, Note b) => _version(a) == _version(b);
String _version(Note n) => jsonEncode([
  n.noteId,
  n.userId,
  n.notebookId,
  n.title,
  n.content,
  n.tags,
  n.usn,
  n.isMarkdown,
  n.isStarred,
  n.isTrash,
  n.isDeleted,
  n.createdTime,
  n.updatedTime,
]);
