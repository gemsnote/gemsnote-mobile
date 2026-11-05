import 'note.dart';

enum NoteSort {
  updatedDescending('修改时间：新到旧'),
  updatedAscending('修改时间：旧到新'),
  createdDescending('创建时间：降序'),
  createdAscending('创建时间：升序'),
  titleAscending('标题：升序'),
  titleDescending('标题：降序');

  const NoteSort(this.label);
  final String label;

  List<Note> apply(Iterable<Note> notes) {
    final result = notes.toList();
    result.sort((a, b) {
      int comparison;
      if (this == titleAscending || this == titleDescending) {
        comparison = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        if (this == titleDescending) comparison = -comparison;
      } else {
        final byCreated = this == createdAscending || this == createdDescending;
        final left = DateTime.tryParse(
          byCreated ? a.createdTime : a.updatedTime,
        );
        final right = DateTime.tryParse(
          byCreated ? b.createdTime : b.updatedTime,
        );
        // Unknown dates always follow valid dates, regardless of direction.
        if (left == null && right != null) return 1;
        if (right == null && left != null) return -1;
        comparison = left == null || right == null ? 0 : left.compareTo(right);
        if (this == updatedDescending || this == createdDescending) {
          comparison = -comparison;
        }
      }
      return comparison == 0 ? a.noteId.compareTo(b.noteId) : comparison;
    });
    return result;
  }
}
