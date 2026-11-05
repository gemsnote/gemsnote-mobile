import 'note.dart';
import 'shared_file.dart';

class SharedNote {
  const SharedNote({
    required this.note,
    required this.version,
    this.files = const [],
  });
  final Note note;
  final String version;
  final List<SharedFile> files;

  Map<String, Object?> toJson() => {
    'NoteId': note.noteId,
    'OwnerUserId': note.userId,
    'NotebookId': note.notebookId,
    'Title': note.title,
    'Tags': note.tags,
    'IsMarkdown': note.isMarkdown,
    'CreatedTime': note.createdTime,
    'UpdatedTime': note.updatedTime,
    'Version': version,
    'Files': files.map((file) => file.toJson()).toList(),
  };

  factory SharedNote.fromJson(Map<String, Object?> data) {
    final id = RegExp(r'^[0-9a-fA-F]{24}$');
    if (data['NoteId'] is! String ||
        !id.hasMatch(data['NoteId'] as String) ||
        data['OwnerUserId'] is! String ||
        !id.hasMatch(data['OwnerUserId'] as String) ||
        data['Title'] is! String ||
        data['IsMarkdown'] is! bool ||
        data['Version'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['Version'] as String)) {
      throw const FormatException('invalidSharedNote');
    }
    return SharedNote(
      note: Note.fromJson({...data, 'UserId': data['OwnerUserId']}),
      version: data['Version'] as String,
      files: (data['Files'] as List? ?? [])
          .map(
            (file) =>
                SharedFile.fromJson(Map<String, Object?>.from(file as Map)),
          )
          .toList(growable: false),
    );
  }
}
