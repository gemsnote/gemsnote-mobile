import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const id = '507f1f77bcf86cd799439012';
  final server = Uri.parse('https://notes.example.test');
  test('receipt lookup and cleanup use bearer API2 only', () async {
    final client = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret');
        expect(request.url.queryParameters.containsKey('token'), false);
        if (request.method == 'GET') {
          expect(request.url.path, '/api2/file/imageUpload');
          expect(request.url.queryParameters['uploadId'], 'stable_upload_key');
          return http.Response(
            jsonEncode({
              'Ok': true,
              'Item': {
                'FileId': id,
                'NoteId': id,
                'Digest': 'a' * 64,
                'State': 'pending',
                'CanCleanup': true,
              },
            }),
            200,
          );
        }
        expect(request.method, 'POST');
        expect(request.url.path, '/api2/file/cleanupImageUpload');
        expect(request.bodyFields['fileId'], id);
        return http.Response('{"Ok":true}', 200);
      }),
    );
    final receipt = await client.imageUploadStatus(
      server: server,
      token: 'secret',
      uploadId: 'stable_upload_key',
    );
    expect(receipt.fileId, id);
    await client.cleanupImageUpload(
      server: server,
      token: 'secret',
      fileId: id,
    );
  });
  test('server cannot advertise cleanup for a retained image', () async {
    final client = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'Ok': true,
            'Item': {
              'FileId': id,
              'NoteId': id,
              'Digest': 'a' * 64,
              'State': 'retained',
              'CanCleanup': true,
            },
          }),
          200,
        ),
      ),
    );
    await expectLater(
      client.imageUploadStatus(
        server: server,
        token: 'secret',
        uploadId: 'stable_upload_key',
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
