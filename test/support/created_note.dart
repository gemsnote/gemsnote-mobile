/// API2 server fixture, retained independently of subsequent create retries.
Map<String, Object?> createdNote(Map<String, String> fields, {int usn = 6}) => {
  'NoteId': fields['ClientNoteId'],
  'UserId': 'u',
  'NotebookId': fields['NotebookId'] ?? '',
  'Title': fields['Title'] ?? '',
  'Content': fields['Content'] ?? '',
  'Tags': [
    for (var i = 0; fields.containsKey('Tags[$i]'); i++) fields['Tags[$i]']!,
  ],
  'IsMarkdown': fields['IsMarkdown'] == 'true',
  'IsStar': fields['IsStar'] == 'true',
  'IsTrash': false,
  'IsDeleted': false,
  'CreatedTime': fields['CreatedTime'] ?? '',
  'UpdatedTime': fields['UpdatedTime'] ?? '',
  'Usn': usn,
  'Files': <Object>[],
};
