import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final server = Uri.parse('https://example.test');
  const id = '507f1f77bcf86cd799439011';
  const file = NoteFile(
    id: id,
    title: 'image.png',
    type: 'png',
    isAttachment: false,
  );
  Map<String, Object?> metadata() => {
    'NoteId': 'note',
    'UserId': 'user',
    'Files': [
      {'FileId': id, 'Title': 'image.png', 'Type': 'png', 'IsAttach': false},
    ],
  };
  test(
    'reads server file IDs, validates membership before token image request',
    () async {
      final paths = <String>[];
      final api = Api2Client(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers.values, contains('Bearer test'));
          if (request.url.path == '/api2/note/getNote') {
            return http.Response(jsonEncode(metadata()), 200);
          }
          expect(request.url.queryParameters['fileId'], id);
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      final bytes = await api.noteImage(
        server: server,
        token: 'test',
        noteId: 'note',
        userId: 'user',
        file: file,
      );
      expect(bytes, [1, 2, 3]);
      expect(paths, ['/api2/note/getNote', '/api2/file/getImage']);
    },
  );
  for (final scenario in [
    'owner',
    'note',
    'missingFiles',
    'invalidFile',
    'duplicate',
    'deleted',
    'denied',
  ]) {
    test('invalid or inaccessible list rejected: $scenario', () async {
      final data = metadata();
      switch (scenario) {
        case 'owner':
          data['UserId'] = 'other';
        case 'note':
          data['NoteId'] = 'other';
        case 'missingFiles':
          data.remove('Files');
        case 'invalidFile':
          (data['Files'] as List).add({'FileId': '../private'});
        case 'duplicate':
          (data['Files'] as List).add((data['Files'] as List).first);
        case 'deleted':
          data['IsDeleted'] = true;
        case 'denied':
          data.addAll({'Ok': false, 'Msg': 'noPermission'});
      }
      final api = Api2Client(
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode(data), 200),
        ),
      );
      await expectLater(
        api.noteFiles(
          server: server,
          token: 'test',
          noteId: 'note',
          userId: 'user',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  }
  test('removed file does not initiate download', () async {
    var calls = 0;
    final api = Api2Client(
      httpClient: MockClient((_) async {
        calls++;
        return http.Response(jsonEncode({...metadata(), 'Files': null}), 200);
      }),
    );
    await expectLater(
      api.noteImage(
        server: server,
        token: 'test',
        noteId: 'note',
        userId: 'user',
        file: file,
      ),
      throwsA(isA<ApiException>()),
    );
    expect(calls, 1);
  });
  for (final scenario in [
    'redirect',
    'html',
    'empty',
    'oversize',
    'streamOversize',
  ]) {
    test('reject unsafe image response: $scenario', () async {
      final api = Api2Client(
        httpClient: MockClient.streaming((request, _) async {
          if (request.url.path == '/api2/note/getNote') {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode(metadata()))),
              200,
            );
          }
          return http.StreamedResponse(
            Stream.value(
              scenario == 'empty'
                  ? []
                  : scenario == 'streamOversize'
                  ? List.filled(8 * 1024 * 1024 + 1, 0)
                  : [1],
            ),
            scenario == 'redirect' ? 302 : 200,
            contentLength: scenario == 'oversize' ? 9 * 1024 * 1024 : null,
            headers: {
              'content-type': scenario == 'html' ? 'text/html' : 'image/png',
              'location': 'https://other.test',
            },
          );
        }),
      );
      await expectLater(
        api.noteImage(
          server: server,
          token: 'test',
          noteId: 'note',
          userId: 'user',
          file: file,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  }
}
