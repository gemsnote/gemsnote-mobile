import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('login uses the finalized API2 JSON contract', () async {
    final client = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api2/auth/login');
        expect(request.url.queryParameters['v'], 'mobile_1.0.0');
        expect(jsonDecode(request.body), {'email': 'admin', 'pwd': 'secret'});
        return http.Response(
          jsonEncode({
            'Ok': true,
            'Token': 'token-1',
            'User': {
              'UserId': '507f1f77bcf86cd799439011',
              'Username': 'admin',
              'Email': 'admin@example.test',
              'Logo': '',
            },
            'Server': {
              'Name': 'gemsnote',
              'Version': '1.0.0',
              'MinVersion': '',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await client.login(
      server: Uri.parse('https://notes.example.test/'),
      identity: 'admin',
      password: 'secret',
    );

    expect(result.token, 'token-1');
    expect(result.account.username, 'admin');
    expect(result.serverVersion, '1.0.0');
  });

  test('new notes use the API2 client form contract', () async {
    late http.Request captured;
    final client = Api2Client(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          '{"NoteId":"507f1f77bcf86cd799439013","NotebookId":"507f1f77bcf86cd799439012","UserId":"507f1f77bcf86cd799439011","Title":"New","Usn":4,"IsMarkdown":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    const note = Note(
      noteId: '507f1f77bcf86cd799439013',
      notebookId: '507f1f77bcf86cd799439012',
      userId: '507f1f77bcf86cd799439011',
      title: 'New',
      content: '# New',
      tags: ['mobile'],
      usn: 0,
      isMarkdown: true,
      isStarred: false,
      isTrash: false,
      isDeleted: false,
      createdTime: '2026-01-01T00:00:00Z',
      updatedTime: '2026-01-01T00:00:00Z',
    );

    final result = await client.addNote(
      server: Uri.parse('https://notes.example.test/'),
      token: 'secret',
      note: note,
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api2/client/note/add');
    final fields = Uri.splitQueryString(captured.body);
    expect(fields['ClientNoteId'], note.noteId);
    expect(fields['NotebookId'], note.notebookId);
    expect(fields['Content'], '# New');
    expect(fields['Tags[0]'], 'mobile');
    expect(result.usn, 4);
  });

  test('note metadata updates use server ids and usn', () async {
    late http.Request captured;
    final client = Api2Client(
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          expect(request.url.path, '/api2/note/getNote');
          expect(
            request.url.queryParameters['noteId'],
            '507f1f77bcf86cd799439013',
          );
          return http.Response(
            jsonEncode({
              'NoteId': '507f1f77bcf86cd799439013',
              'Usn': 7,
              'Files': [
                {
                  'FileId': '507f1f77bcf86cd799439099',
                  'IsAttach': true,
                  'Type': 'pdf',
                  'Title': 'keep.pdf',
                },
                {
                  'FileId': '507f1f77bcf86cd799439098',
                  'IsAttach': false,
                  'Type': 'png',
                  'Title': 'image.png',
                },
              ],
            }),
            200,
          );
        }
        captured = request;
        return http.Response(
          '{"NoteId":"507f1f77bcf86cd799439013","NotebookId":"507f1f77bcf86cd799439099","UserId":"507f1f77bcf86cd799439011","Title":"Moved","Usn":8,"IsStar":true}',
          200,
        );
      }),
    );
    const note = Note(
      noteId: '507f1f77bcf86cd799439013',
      notebookId: '507f1f77bcf86cd799439099',
      userId: '507f1f77bcf86cd799439011',
      title: 'Moved',
      content: 'body',
      tags: [],
      usn: 7,
      isMarkdown: false,
      isStarred: true,
      isTrash: false,
      isDeleted: false,
      createdTime: '2026-01-01T00:00:00Z',
      updatedTime: '2026-01-02T00:00:00Z',
    );

    await client.updateNote(
      server: Uri.parse('https://notes.example.test/'),
      token: 'secret',
      note: note,
    );

    expect(captured.url.path, '/api2/client/note/update');
    final fields = Uri.splitQueryString(captured.body);
    expect(fields['NoteId'], note.noteId);
    expect(fields['NotebookId'], note.notebookId);
    expect(fields['Usn'], '7');
    expect(fields['IsStar'], 'true');
    expect(fields['Files[0][FileId]'], '507f1f77bcf86cd799439099');
    expect(fields['Files[0][IsAttach]'], 'true');
    expect(fields['Files[0][HasBody]'], 'false');
    expect(fields['Files[1][IsAttach]'], 'false');
  });

  test('login rejects a non-Gemsnote server response', () async {
    final client = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'Ok': true,
            'Token': 'token-1',
            'User': {'UserId': 'user-1'},
            'Server': {'Name': 'leanote', 'Version': '1.0.0'},
          }),
          200,
        ),
      ),
    );

    expect(
      () => client.login(
        server: Uri.parse('https://notes.example.test/'),
        identity: 'admin',
        password: 'secret',
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'serverMigrationRequired',
        ),
      ),
    );
  });
}
