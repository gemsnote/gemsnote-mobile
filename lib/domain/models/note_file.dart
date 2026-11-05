class NoteFile {
  const NoteFile({
    required this.id,
    required this.title,
    required this.type,
    required this.isAttachment,
    this.cacheGeneration = '',
  });
  final String id;
  final String title;
  final String type;
  final bool isAttachment;
  final String cacheGeneration;

  factory NoteFile.fromJson(Map<String, Object?> json) {
    if (json['FileId'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(json['FileId'] as String) ||
        json['IsAttach'] is! bool ||
        json['Title'] is! String ||
        json['Type'] is! String) {
      throw const FormatException('invalidNoteFile');
    }
    return NoteFile(
      id: json['FileId'] as String,
      title: json['Title'] as String,
      type: json['Type'] as String,
      isAttachment: json['IsAttach'] as bool,
    );
  }
}
