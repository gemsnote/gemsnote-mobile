import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('password reset uses unauthenticated API2 JSON request', () async {
    final api = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api2/auth/password/request');
        expect(request.url.queryParameters.containsKey('token'), false);
        expect(jsonDecode(request.body), {'email': 'user@example.test'});
        expect(request.headers['content-type'], contains('application/json'));
        return http.Response('{"Ok":true}', 200);
      }),
    );
    await api.requestPasswordReset(
      server: Uri.parse('https://notes.example.test/'),
      email: 'user@example.test',
    );
  });
  test('mail failure does not report success', () async {
    final api = Api2Client(
      httpClient: MockClient(
        (_) async => http.Response('{"Ok":false,"Msg":"sendEmailError"}', 200),
      ),
    );
    await expectLater(
      api.requestPasswordReset(
        server: Uri.parse('https://notes.example.test/'),
        email: 'user@example.test',
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
