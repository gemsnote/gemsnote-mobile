import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const noteId = '507f1f77bcf86cd799439011';
  Map<String, Object?> tombstone(int usn) => {
    'NoteId': noteId,
    'UserId': 'u',
    'NotebookId': 'b',
    'Title': 'Deleted',
    'Tags': <String>[],
    'Usn': usn,
    'IsMarkdown': true,
    'IsStar': false,
    'IsTrash': true,
    'IsDeleted': true,
    'CreatedTime': '2025-01-01',
    'UpdatedTime': '2026-01-01',
  };

  test('deleted note snapshot reads a stable tombstone without requesting removed body', () async {
    final paths = <String>[];
    final api = Api2Client(
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(jsonEncode(tombstone(8)), 200);
      }),
    );
    final snapshot = await api.getConflictSnapshot(
      server: Uri.parse('https://example.test'),
      token: 'secret',
      noteId: noteId,
    );
    expect(paths, ['/api2/note/getNote', '/api2/note/getNote']);
    expect(snapshot.note.isDeleted, isTrue);
    expect(snapshot.note.content, isEmpty);
    expect(snapshot.filesConfirmedEmpty, isFalse);
  });

  test('changed deletion tombstone is rejected', () async {
    var reads = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        reads++;
        return http.Response(jsonEncode(tombstone(reads + 7)), 200);
      }),
    );
    await expectLater(
      api.getConflictSnapshot(
        server: Uri.parse('https://example.test'),
        token: 'secret',
        noteId: noteId,
      ),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'conflict')),
    );
    expect(reads, 2);
  });
}
