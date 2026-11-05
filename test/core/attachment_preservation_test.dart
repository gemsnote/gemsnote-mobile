import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const id = '507f1f77bcf86cd799439013';
  final note = Note.fromJson({
    'NoteId': id,
    'Usn': 7,
    'Title': 'Local edit',
    'Content': 'Keep this',
  });
  for (final (label, payload, code) in [
    ('changed USN', {'NoteId': id, 'Usn': 8, 'Files': []}, 'conflict'),
    ('missing file list', {'NoteId': id, 'Usn': 7}, 'invalidResponse'),
    (
      'invalid file',
      {
        'NoteId': id,
        'Usn': 7,
        'Files': [
          {'FileId': '', 'IsAttach': true},
        ],
      },
      'invalidResponse',
    ),
  ]) {
    test('$label prevents destructive update', () async {
      var writes = 0;
      final api = Api2Client(
        httpClient: MockClient((request) async {
          if (request.method == 'POST') writes++;
          return http.Response(jsonEncode(payload), 200);
        }),
      );
      await expectLater(
        api.updateNote(
          server: Uri.parse('https://notes.example.test/'),
          token: 'test',
          note: note,
        ),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
      );
      expect(writes, 0);
    });
  }

  test('explicitly empty attachments allow note update', () async {
    var writes = 0;
    final api = Api2Client(
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          writes++;
          expect(
            request.bodyFields.keys.where((k) => k.startsWith('Files')),
            isEmpty,
          );
        }
        return http.Response(
          jsonEncode({'NoteId': id, 'Usn': 7, 'Files': null}),
          200,
        );
      }),
    );
    await api.updateNote(
      server: Uri.parse('https://notes.example.test/'),
      token: 'test',
      note: note,
    );
    expect(writes, 1);
  });
}
