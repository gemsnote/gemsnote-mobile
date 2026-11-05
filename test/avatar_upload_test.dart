import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/services/avatar_picker.dart';
import 'package:gemsnote/ui/avatar_upload_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'note_import_test.dart' show PickedSource;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = File('assets/images/gemsnote_s.png').readAsBytesSync();
  test('normalization limits dimensions and retains aspect ratio', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff173d38), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final source = await picture.toImage(512, 128);
    final data = await source.toByteData(format: ui.ImageByteFormat.png);
    final normalized = await AvatarPicker.normalize(data!.buffer.asUint8List());
    final codec = await ui.instantiateImageCodec(normalized);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 256);
    expect(frame.image.height, 64);
    frame.image.dispose();
    codec.dispose();
    source.dispose();
    picture.dispose();
  });
  test('picker cancel, actual format, size and corrupt image checks', () async {
    expect(await AvatarPicker(pick: () async => null).pick(), isNull);
    final result = await AvatarPicker(
      pick: () async => PickedSource('photo.png', png),
    ).pick();
    expect(result, isNotNull);
    expect(result!.take(8), png.take(8));
    await expectLater(
      AvatarPicker.normalize(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    await expectLater(
      AvatarPicker.normalize(Uint8List(AvatarPicker.maxBytes + 1)),
      throwsFormatException,
    );
    await expectLater(
      AvatarPicker.normalize(Uint8List.fromList(png.take(10).toList())),
      throwsA(isA<Object>()),
    );
    final oversized = PickedSource(
      'photo.png',
      png,
      reportedSize: AvatarPicker.maxBytes + 1,
    );
    await expectLater(
      AvatarPicker(pick: () async => oversized).pick(),
      throwsFormatException,
    );
    expect(oversized.read, false);
  });
  for (final scenario in ['ok', 'rejected']) {
    test('avatar session multipart contract: $scenario', () async {
      var uploads = 0;
      final paths = <String>[];
      final api = Api2Client(
        httpClient: MockClient((r) async {
          paths.add(r.url.path);
          expect(r.followRedirects, false);
          expect(r.url.queryParameters, isEmpty);
          switch (r.url.path) {
            case '/api2/avatar':
              uploads++;
              expect(r.headers.values, contains('Bearer test-token'));
              expect(
                r.headers['content-type'],
                startsWith('multipart/form-data; boundary='),
              );
              final body = latin1.decode(r.bodyBytes);
              expect(body, contains('name="file"; filename="avatar.png"'));
              expect(body, contains(latin1.decode(png)));
              expect(body, isNot(contains('secret-password')));
              return http.Response(
                jsonEncode({'Ok': scenario == 'ok', 'Id': 'file-id'}),
                200,
              );
            default:
              fail('unexpected request');
          }
        }),
      );
      final result = api.uploadAvatar(
        server: Uri.parse('https://notes.test'),
        token: 'test-token',
        bytes: png,
      );
      if (scenario == 'ok') {
        await result;
      } else {
        await expectLater(result, throwsA(isA<ApiException>()));
      }
      expect(uploads, 1);
      expect(paths.last, '/api2/avatar');
    });
  }
  testWidgets('upload failure retains preview and reports error', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AvatarUploadDialog(
            bytes: png,
            upload: () async {
              calls++;
              throw StateError('failed');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('上传失败'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
