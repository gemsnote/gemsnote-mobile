import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/services/note_image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'note_import_test.dart' show PickedSource;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = File('assets/images/gemsnote_s.png').readAsBytesSync();
  test(
    'picker preserves dimensions and returns immutable normalized PNG',
    () async {
      expect(await NoteImagePicker(pick: () async => null).pick(), isNull);
      final result = await NoteImagePicker(
        pick: () async => PickedSource('image.png', png),
      ).pick();
      expect(result!.bytes.take(8), png.take(8));
      expect(() => result.bytes[0] = 0, throwsUnsupportedError);
      final codec = await ui.instantiateImageCodec(result.bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 256);
      expect(frame.image.height, 256);
      frame.image.dispose();
      codec.dispose();
    },
  );
  test('rejects oversized, SVG, and corrupt files before upload', () async {
    final big = PickedSource(
      'image.png',
      png,
      reportedSize: NoteImageUpload.maxBytes + 1,
    );
    await expectLater(
      NoteImagePicker(pick: () async => big).pick(),
      throwsFormatException,
    );
    expect(big.read, false);
    await expectLater(
      NoteImageUpload.normalize(Uint8List.fromList(utf8.encode('<svg/>'))),
      throwsFormatException,
    );
    await expectLater(
      NoteImageUpload.normalize(Uint8List.fromList(png.take(10).toList())),
      throwsA(isA<Object>()),
    );
  });
  for (final scenario in ['ok', 'foreign-note', 'missing-id']) {
    test(
      'image API2 upload uses PNG, note permission and temporary session: $scenario',
      () async {
        const noteId = '507f1f77bcf86cd799439011';
        const imageId = '507f1f77bcf86cd799439012';
        var uploads = 0;
        var markedSending = false;
        var logouts = 0;
        final api = Api2Client(
          httpClient: MockClient((request) async {
            switch (request.url.path) {
              case '/api2/note/getNote':
                return http.Response(
                  jsonEncode({
                    'NoteId': noteId,
                    'UserId': scenario == 'foreign-note' ? 'other' : 'u',
                  }),
                  200,
                );
              case '/api2/file/pasteImage':
                expect(markedSending, isTrue);
                uploads++;
                expect(request.followRedirects, false);
                expect(request.headers.values, contains('Bearer secret'));
                expect(request.url.queryParameters, isEmpty);
                expect(
                  request.headers['content-type'],
                  startsWith('multipart/form-data'),
                );
                final body = latin1.decode(request.bodyBytes);
                expect(body, contains('name="noteId"'));
                expect(body, contains(noteId));
                expect(body, contains('filename="image.png"'));
                return http.Response(
                  jsonEncode({
                    'Ok': true,
                    'Id': scenario == 'missing-id' ? '' : imageId,
                  }),
                  200,
                );
            }
            throw StateError('Unexpected request');
          }),
        );
        final future = api.uploadNoteImage(
          server: Uri.parse('https://example.com'),
          token: 'secret',
          userId: 'u',
          noteId: noteId,
          image: await NoteImageUpload.normalize(png),
          beforeSend: () async {
            markedSending = true;
          },
        );
        if (scenario == 'ok') {
          expect(await future, '/api2/file/getImage?fileId=$imageId');
        } else {
          await expectLater(future, throwsA(isA<ApiException>()));
        }
        expect(uploads, scenario == 'foreign-note' ? 0 : 1);
        expect(logouts, 0);
        expect(markedSending, scenario != 'foreign-note');
      },
    );
  }
}
