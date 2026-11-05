import 'notebook.dart';

class NotebookConflictSnapshot {
  NotebookConflictSnapshot({
    required this.accountId,
    required this.local,
    required this.remote,
    required Iterable<Notebook> remoteBooks,
  }) : remoteBooks = List.unmodifiable(remoteBooks);
  final String accountId;
  final Notebook local, remote;
  final List<Notebook> remoteBooks;
}

bool sameNotebookVersion(Notebook a, Notebook b) =>
    a.notebookId == b.notebookId &&
    a.usn == b.usn &&
    a.title == b.title &&
    a.parentNotebookId == b.parentNotebookId &&
    a.sequence == b.sequence &&
    a.isDeleted == b.isDeleted;
