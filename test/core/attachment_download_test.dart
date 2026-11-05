import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const file = NoteFile(
    id: '507f1f77bcf86cd799439011',
    title: 'doc.pdf',
    type: 'pdf',
    isAttachment: true,
  );
  for (final scenario in [
    'ok',
    'empty',
    'removed',
    'image',
    'owner',
    'redirect',
    'errorBody',
    'oversize',
    'streamOversize',
  ]) {
    test('attachment download $scenario', () async {
      var downloads = 0;
      final api = Api2Client(
        httpClient: MockClient.streaming((request, _) async {
          expect(request.method, 'GET');
          expect(request.headers.values, contains('Bearer test'));
          if (request.url.path == '/api2/note/getNote') {
            expect(request.url.queryParameters['noteId'], 'note');
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'NoteId': 'note',
                    'UserId': scenario == 'owner' ? 'other' : 'user',
                    'Files': scenario == 'removed'
                        ? []
                        : [
                            {
                              'FileId': file.id,
                              'Title': file.title,
                              'Type': 'pdf',
                              'IsAttach': scenario != 'image',
                            },
                          ],
                  }),
                ),
              ),
              200,
            );
          }
          downloads++;
          expect(request.url.path, '/api2/file/getAttach');
          expect(request.url.queryParameters['fileId'], file.id);
          expect(request.followRedirects, isFalse);
          return http.StreamedResponse(
            Stream.value(
              scenario == 'empty'
                  ? []
                  : scenario == 'streamOversize'
                  ? List.filled(32 * 1024 * 1024 + 1, 0)
                  : [1, 2, 3],
            ),
            scenario == 'redirect' ? 302 : 200,
            contentLength: scenario == 'oversize' ? 33 * 1024 * 1024 : null,
            headers: scenario == 'errorBody'
                ? {}
                : {'content-disposition': 'attachment; filename="ignored.pdf"'},
          );
        }),
      );
      final result = api.noteAttachment(
        server: Uri.parse('https://example.test'),
        token: 'test',
        noteId: 'note',
        userId: 'user',
        file: file,
      );
      if (scenario == 'ok' || scenario == 'empty') {
        expect(await result, scenario == 'empty' ? isEmpty : [1, 2, 3]);
      } else {
        await expectLater(result, throwsA(isA<ApiException>()));
      }
      expect(
        downloads,
        ['removed', 'owner', 'image'].contains(scenario) ? 0 : 1,
      );
    });
  }
}
