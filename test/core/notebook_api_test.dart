import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('creation key must be acknowledged with the same notebook ID', () async {
    const id = '507f1f77bcf86cd799439012';
    final client = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.bodyFields['clientNotebookId'], id);
        return http.Response(
          jsonEncode({
            'NotebookId': '507f1f77bcf86cd799439013',
            'Title': 'book',
            'Usn': 5,
          }),
          200,
        );
      }),
    );
    await expectLater(
      client.saveNotebook(
        server: Uri.parse('https://notes.example.test'),
        token: 't',
        title: 'book',
        clientNotebookId: id,
      ),
      throwsA(isA<ApiException>()),
    );
  });
  test('create child and rename retain server identity and parent', () async {
    const id = '507f1f77bcf86cd799439012';
    const parent = '507f1f77bcf86cd799439013';
    var calls = 0;
    final client = Api2Client(
      httpClient: MockClient((request) async {
        calls++;
        expect(request.method, 'POST');
        expect(request.headers.values, contains('Bearer test-token'));
        final fields = request.bodyFields;
        expect(fields['parentNotebookId'], parent);
        if (calls == 1) {
          expect(request.url.path, '/api2/client/notebook/add');
          expect(fields.containsKey('notebookId'), false);
        } else {
          expect(request.url.path, '/api2/client/notebook/update');
          expect(fields['notebookId'], id);
          expect(fields['usn'], '12');
          expect(fields['title'], 'Renamed');
        }
        return http.Response(
          jsonEncode({
            'NotebookId': id,
            'ParentNotebookId': parent,
            'Title': fields['title'],
            'Seq': 0,
            'Usn': calls == 1 ? 12 : 13,
          }),
          200,
        );
      }),
    );
    final server = Uri.parse('https://notes.example.test/');
    final created = await client.saveNotebook(
      server: server,
      token: 'test-token',
      title: 'Child',
      parentNotebookId: parent,
    );
    final renamed = await client.saveNotebook(
      server: server,
      token: 'test-token',
      title: 'Renamed',
      existing: created,
    );
    expect(renamed.notebookId, created.notebookId);
    expect(renamed.usn, 13);
  });

  test('business errors cannot be cached as notebooks', () async {
    final client = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response('{"Ok":false,"Msg":"conflict"}', 200),
      ),
    );
    await expectLater(
      client.saveNotebook(
        server: Uri.parse('https://notes.example.test/'),
        token: 'test-token',
        title: 'Child',
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
