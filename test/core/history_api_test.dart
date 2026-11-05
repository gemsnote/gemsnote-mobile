import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final server = Uri.parse('https://notes.example.test/');
  test(
    'complete history restore sends stable ID and expected USN through API2',
    () async {
      final api = Api2Client(
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api2/note/restoreHistory');
          expect(request.headers.values, contains('Bearer test'));
          expect(request.bodyFields, {
            'noteId': 'n',
            'historyId': 'h',
            'usn': '12',
          });
          expect(request.followRedirects, isFalse);
          return http.Response('{"Ok":true}', 200);
        }),
      );
      await api.restoreHistorySnapshot(
        server: server,
        token: 'test',
        noteId: 'n',
        historyId: 'h',
        usn: 12,
      );
    },
  );
  for (final message in [
    'conflict',
    'historyFileMissing',
    'historyFilesUnknown',
    'noAuth',
  ]) {
    test('complete restore exposes server rejection: $message', () async {
      final api = Api2Client(
        httpClient: MockClient(
          (_) async =>
              http.Response(jsonEncode({'Ok': false, 'Msg': message}), 200),
        ),
      );
      await expectLater(
        api.restoreHistorySnapshot(
          server: server,
          token: 'test',
          noteId: 'n',
          historyId: 'h',
          usn: 12,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  }

  test('history body uses stable id rather than list index', () async {
    final api = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.queryParameters['noteId'], 'note-id');
        expect(request.headers.values, contains('Bearer test'));
        if (request.url.path == '/api2/note/getHistories') {
          return http.Response(
            jsonEncode({
              'Ok': true,
              'Item': [
                {
                  'HistoryId': 'stable-id',
                  'Index': 9,
                  'UpdatedTime': '2026-01-01',
                  'UpdatedUserId': 'user',
                },
              ],
            }),
            200,
          );
        }
        expect(request.url.path, '/api2/note/getHistoryContent');
        expect(request.url.queryParameters['historyId'], 'stable-id');
        expect(request.url.queryParameters.containsKey('index'), false);
        return http.Response(
          '{"Ok":true,"Item":{"HistoryId":"stable-id","Content":""}}',
          200,
        );
      }),
    );
    final versions = await api.getHistories(
      server: server,
      token: 'test',
      noteId: 'note-id',
    );
    expect(
      await api.getHistoryContent(
        server: server,
        token: 'test',
        noteId: 'note-id',
        historyId: versions.single.id,
      ),
      '',
    );
  });

  test('empty history list is valid', () async {
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response('{"Ok":true,"Item":[]}', 200),
      ),
    );
    expect(
      await api.getHistories(server: server, token: 'test', noteId: 'n'),
      isEmpty,
    );
  });

  test('mismatched history id is rejected', () async {
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response(
          '{"Ok":true,"Item":{"HistoryId":"other","Content":"wrong version"}}',
          200,
        ),
      ),
    );
    await expectLater(
      api.getHistoryContent(
        server: server,
        token: 'test',
        noteId: 'n',
        historyId: 'wanted',
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test('permission errors remain visible', () async {
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response('{"Ok":false,"Msg":"noteNotExists"}', 200),
      ),
    );
    await expectLater(
      api.getHistories(server: server, token: 'test', noteId: 'n'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'noteNotExists'),
      ),
    );
  });
}
