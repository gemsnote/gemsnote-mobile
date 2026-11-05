class SharedFile {
  const SharedFile({
    required this.noteId,
    required this.fileId,
    required this.kind,
    required this.title,
    required this.size,
    required this.version,
  });
  final String noteId;
  final String fileId;
  final String kind;
  final String title;
  final int size;
  final String version;
  bool get isAttachment => kind == 'attachment';
  int get maxBytes => (isAttachment ? 32 : 8) * 1024 * 1024;

  Map<String, Object?> toJson() => {
    'NoteId': noteId,
    'FileId': fileId,
    'Kind': kind,
    'Title': title,
    'Size': size,
    'Version': version,
  };

  bool sameVersion(SharedFile other) =>
      noteId == other.noteId &&
      fileId == other.fileId &&
      kind == other.kind &&
      size == other.size &&
      version == other.version;

  factory SharedFile.fromJson(Map<String, Object?> data) {
    final id = RegExp(r'^[0-9a-fA-F]{24}$');
    if (data['NoteId'] is! String ||
        !id.hasMatch(data['NoteId'] as String) ||
        data['FileId'] is! String ||
        !id.hasMatch(data['FileId'] as String) ||
        !{'image', 'attachment'}.contains(data['Kind']) ||
        (data['Title'] != null && data['Title'] is! String) ||
        data['Size'] is! int ||
        (data['Size'] as int) < 0 ||
        data['Version'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['Version'] as String)) {
      throw const FormatException('invalidSharedFile');
    }
    return SharedFile(
      noteId: data['NoteId'] as String,
      fileId: data['FileId'] as String,
      kind: data['Kind'] as String,
      title: data['Title'] as String? ?? '',
      size: data['Size'] as int,
      version: data['Version'] as String,
    );
  }
}
