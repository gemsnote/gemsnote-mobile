class Note {
  const Note({
    required this.noteId,
    required this.notebookId,
    required this.userId,
    required this.title,
    required this.content,
    required this.tags,
    required this.usn,
    required this.isMarkdown,
    required this.isStarred,
    required this.isTrash,
    required this.isDeleted,
    required this.createdTime,
    required this.updatedTime,
    this.isShared = false,
  });

  final String noteId;
  final String notebookId;
  final String userId;
  final String title;
  final String content;
  final List<String> tags;
  final int usn;
  final bool isMarkdown;
  final bool isStarred;
  final bool isTrash;
  final bool isDeleted;
  final String createdTime;
  final String updatedTime;
  final bool isShared;

  Note copyWith({
    String? noteId,
    String? notebookId,
    String? userId,
    String? title,
    String? content,
    List<String>? tags,
    int? usn,
    bool? isMarkdown,
    bool? isStarred,
    bool? isTrash,
    bool? isDeleted,
    String? createdTime,
    String? updatedTime,
    bool? isShared,
  }) => Note(
    isShared: isShared ?? this.isShared,
    noteId: noteId ?? this.noteId,
    notebookId: notebookId ?? this.notebookId,
    userId: userId ?? this.userId,
    title: title ?? this.title,
    content: content ?? this.content,
    tags: tags ?? this.tags,
    usn: usn ?? this.usn,
    isMarkdown: isMarkdown ?? this.isMarkdown,
    isStarred: isStarred ?? this.isStarred,
    isTrash: isTrash ?? this.isTrash,
    isDeleted: isDeleted ?? this.isDeleted,
    createdTime: createdTime ?? this.createdTime,
    updatedTime: updatedTime ?? this.updatedTime,
  );

  factory Note.fromJson(Map<String, Object?> json) => Note(
    isShared: json['IsShared'] == true,
    noteId: json['NoteId']?.toString() ?? '',
    notebookId: json['NotebookId']?.toString() ?? '',
    userId: json['UserId']?.toString() ?? '',
    title: json['Title']?.toString() ?? '',
    content: json['Content']?.toString() ?? '',
    tags: (json['Tags'] as List? ?? const [])
        .map((tag) => tag.toString())
        .toList(growable: false),
    usn: json['Usn'] is num
        ? (json['Usn'] as num).toInt()
        : int.tryParse('${json['Usn']}') ?? 0,
    isMarkdown: json['IsMarkdown'] == true,
    isStarred:
        json['IsStar'] == true ||
        json['IsStarred'] == true ||
        json['Starred'] == true,
    isTrash: json['IsTrash'] == true,
    isDeleted: json['IsDeleted'] == true,
    createdTime: json['CreatedTime']?.toString() ?? '',
    updatedTime: json['UpdatedTime']?.toString() ?? '',
  );
}
