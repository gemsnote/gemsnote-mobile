import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Test setup only: provision users through the administrator API2 endpoint.
/// All requests still pass through the caller's loopback/API2-only client.
class FixtureSession {
  FixtureSession(this.client, this.server);
  final http.Client client;
  final Uri server;
  String _token = '';

  Future<void> login(String identity, String password) async {
    final result = await request('/api2/auth/login', {
      'email': identity,
      'pwd': password,
    }, json: true);
    expect(result['Ok'], isTrue);
    _token = result['Token'] as String? ?? '';
    expect(_token, isNotEmpty);
  }

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, String> fields, {
    bool json = false,
  }) async => await _request(path, fields, json: json) as Map<String, dynamic>;

  Future<void> revokeNote(String noteId, String recipientId) async {
    expect(
      await _request('/api2/share/deleteShareNote', {
        'noteId': noteId,
        'toUserId': recipientId,
      }),
      isTrue,
    );
  }

  Future<Object?> _request(
    String path,
    Map<String, String> fields, {
    bool json = false,
  }) async {
    final request = http.Request('POST', server.resolve(path))
      ..followRedirects = false
      ..headers['X-Requested-With'] = 'XMLHttpRequest';
    if (_token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $_token';
    }
    if (json) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(fields);
    } else {
      request.bodyFields = fields;
    }
    final response = await http.Response.fromStream(await client.send(request))
        .timeout(const Duration(seconds: 30));
    expect(response.statusCode, 200);
    return jsonDecode(response.body);
  }

  Future<void> close() async {
    await _request('/api2/logout', {});
    _token = '';
  }
}
