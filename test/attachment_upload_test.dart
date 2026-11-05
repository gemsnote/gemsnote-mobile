import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/services/attachment_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'note_import_test.dart' show PickedSource;

void main() {
  test(
    'attachment picker cancellation, basename and size validation',
    () async {
      expect(await AttachmentPicker(pick: () async => null).pick(), isNull);
      final picked = await AttachmentPicker(
        pick: () async =>
            PickedSource('dir/example.txt', Uint8List.fromList([1, 2])),
      ).pick();
      expect(picked!.name, 'example.txt');
      expect(picked.bytes, [1, 2]);
      final oversized = PickedSource(
        'big.bin',
        Uint8List(1),
        reportedSize: AttachmentUpload.maxBytes + 1,
      );
      await expectLater(
        AttachmentPicker(pick: () async => oversized).pick(),
        throwsFormatException,
      );
      expect(oversized.read, false);
      expect(
        () => AttachmentUpload(name: 'a', bytes: Uint8List(0)),
        throwsFormatException,
      );
      expect(
        () => AttachmentUpload(name: '../a', bytes: Uint8List(1)),
        throwsFormatException,
      );
      expect(
        () => AttachmentUpload(name: 'a\r\nb', bytes: Uint8List(1)),
        throwsFormatException,
      );
    },
  );
  for (final scenario in [
    'ok',
    'foreign-note',
    'rejected',
    'unknown-result',
    'journal-failure',
  ]) {
    test('API2 attachment upload contract: $scenario', () async {
      const noteId = '507f1f77bcf86cd799439011';
      const fileId = '507f1f77bcf86cd799439012';
      var uploads = 0;
      var markedSending = false;
      final paths = <String>[];
      final api = Api2Client(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          switch (request.url.path) {
            case '/api2/note/getNote':
              expect(request.headers.values, contains('Bearer t'));
              return http.Response(
                jsonEncode({
                  'NoteId': noteId,
                  'UserId': scenario == 'foreign-note' ? 'other' : 'u',
                }),
                200,
              );
            case '/api2/attachments/upload':
              expect(request.headers.values, contains('Bearer t'));
              expect(markedSending, isTrue);
              uploads++;
              expect(request.method, 'POST');
              expect(request.followRedirects, false);
              expect(
                request.headers['content-type'],
                startsWith('multipart/form-data'),
              );
              expect(request.body, contains('name="noteId"'));
              expect(request.body, contains(noteId));
              expect(
                request.body,
                contains('name="file"; filename="example.txt"'),
              );
              expect(request.body, contains('payload'));
              return http.Response(
                jsonEncode({
                  'Ok': scenario != 'rejected',
                  'Id': scenario == 'unknown-result' ? '' : fileId,
                  'Msg': 'denied',
                }),
                200,
              );
          }
          throw StateError('Unexpected request ${request.url.path}');
        }),
      );
      final future = api.uploadAttachment(
        server: Uri.parse('https://example.com'),
        token: 't',
        userId: 'u',
        noteId: noteId,
        beforeSend: () async {
          if (scenario == 'journal-failure') throw StateError('disk full');
          markedSending = true;
        },
        file: AttachmentUpload(
          name: 'example.txt',
          bytes: Uint8List.fromList(utf8.encode('payload')),
        ),
      );
      if (scenario == 'ok') {
        expect(await future, fileId);
      } else if (scenario == 'journal-failure') {
        await expectLater(future, throwsStateError);
      } else {
        await expectLater(future, throwsA(isA<ApiException>()));
      }
      expect(
        uploads,
        ['foreign-note', 'journal-failure'].contains(scenario) ? 0 : 1,
      );
      expect(
        markedSending,
        !['foreign-note', 'journal-failure'].contains(scenario),
      );
      if (!['foreign-note', 'journal-failure'].contains(scenario)) {
        expect(paths.last, '/api2/attachments/upload');
      }
    });
  }
}
