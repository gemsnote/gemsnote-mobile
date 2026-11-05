class Notebook {
  const Notebook({
    required this.notebookId,
    required this.parentNotebookId,
    required this.title,
    required this.sequence,
    required this.usn,
    required this.numberNotes,
    required this.isDeleted,
    this.isDirty = false,
  });

  final String notebookId;
  final String parentNotebookId;
  final String title;
  final int sequence;
  final int usn;
  final int numberNotes;
  final bool isDeleted;
  final bool isDirty;

  factory Notebook.fromJson(Map<String, Object?> json) => Notebook(
    notebookId: json['NotebookId']?.toString() ?? '',
    parentNotebookId: json['ParentNotebookId']?.toString() ?? '',
    title: json['Title']?.toString() ?? '',
    sequence: _integer(json['Seq']),
    usn: _integer(json['Usn']),
    numberNotes: _integer(json['NumberNotes']),
    isDeleted: json['IsDeleted'] == true,
  );
}

int _integer(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
