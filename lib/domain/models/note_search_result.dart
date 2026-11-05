/// A search row cannot be saved as a note: its body has not been loaded.
class NoteSearchResult {
  const NoteSearchResult({
    required this.noteId,
    required this.title,
    required this.updatedTime,
    required this.isMarkdown,
  });

  final String noteId;
  final String title;
  final String updatedTime;
  final bool isMarkdown;
}
