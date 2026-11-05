import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:http/io_client.dart';

void main() {
  for (final status in [301, 302, 303, 307, 308]) {
    for (final operation in ['get', 'json', 'form']) {
      test('$operation refuses HTTP $status redirects to Legacy API', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final transport = IOClient();
        final paths = <String>[];
        final bodies = <String>[];
        final subscription = server.listen((request) async {
          paths.add(request.uri.path);
          bodies.add(await SystemEncoding().decoder.bind(request).join());
          request.response.statusCode = status;
          request.response.headers.set('location', '/api/legacy-target');
          request.response.write('{"Ok":true}');
          await request.response.close();
        });
        try {
          final client = Api2Client(httpClient: transport);
          final origin = Uri.parse('http://127.0.0.1:${server.port}');
          final Future<Object?> result;
          switch (operation) {
            case 'get':
              result = client.getSyncUsn(
                server: origin,
                token: 'private-token',
              );
            case 'json':
              result = client.login(
                server: origin,
                identity: 'user',
                password: 'private-password',
              );
            default:
              result = client.saveNotebook(
                server: origin,
                token: 'private-token',
                title: 'Personal',
              );
          }
          await expectLater(result, throwsA(isA<ApiException>()));
          expect(paths, hasLength(1));
          expect(paths.single, startsWith('/api2/'));
          if (operation == 'json') {
            expect(bodies.single, contains('private-password'));
          }
          if (operation == 'form') {
            expect(bodies.single, contains('title=Personal'));
          }
        } finally {
          transport.close();
          await subscription.cancel();
          await server.close(force: true);
        }
      });
    }
  }
}
