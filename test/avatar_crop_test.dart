import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/avatar_picker.dart';
import 'package:gemsnote/ui/avatar_crop_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('crop is square, clamps all edges and rejects nonfinite inputs', () {
    expect(
      avatarCropRect(const Size(600, 200), const Offset(.5, .5), 1),
      const Rect.fromLTWH(200, 0, 200, 200),
    );
    expect(
      avatarCropRect(const Size(600, 200), const Offset(-10, 10), 2),
      const Rect.fromLTWH(0, 100, 100, 100),
    );
    expect(
      () => avatarCropRect(Size.zero, Offset.zero, 1),
      throwsArgumentError,
    );
    expect(
      () => avatarCropRect(const Size(20, 20), Offset.zero, double.nan),
      throwsArgumentError,
    );
    expect(
      () => avatarCropRect(
        const Size(20, 20),
        const Offset(double.infinity, 0),
        1,
      ),
      throwsArgumentError,
    );
  });
  test(
    'crop exports requested pixels in a metadata-free 256 square PNG',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 256, 256),
        Paint()..color = const Color(0xffff0000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(256, 0, 256, 256),
        Paint()..color = const Color(0xff0000ff),
      );
      final picture = recorder.endRecording();
      final source = await picture.toImage(512, 256);
      for (final right in [false, true]) {
        final bytes = await cropAvatar(
          source,
          Rect.fromLTWH(right ? 256 : 0, 0, 256, 256),
        );
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        expect(image.width, 256);
        expect(image.height, 256);
        final rgba = (await image.toByteData())!.buffer.asUint8List();
        final pixel = (128 * 256 + 128) * 4;
        expect(
          rgba.sublist(pixel, pixel + 4),
          right ? [0, 0, 255, 255] : [255, 0, 0, 255],
        );
        image.dispose();
        codec.dispose();
      }
      await expectLater(
        cropAvatar(source, const Rect.fromLTWH(-1, 0, 256, 256)),
        throwsArgumentError,
      );
      source.dispose();
      picture.dispose();
    },
  );
  test(
    'GIF and BMP are decoded and normalized, not uploaded in original formats',
    () async {
      final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
      );
      final bmp = Uint8List(62);
      final header = ByteData.sublistView(bmp);
      bmp[0] = 66;
      bmp[1] = 77;
      header.setUint32(2, 62, Endian.little);
      header.setUint32(10, 54, Endian.little);
      header.setUint32(14, 40, Endian.little);
      header.setInt32(18, 2, Endian.little);
      header.setInt32(22, 1, Endian.little);
      header.setUint16(26, 1, Endian.little);
      header.setUint16(28, 24, Endian.little);
      header.setUint32(34, 8, Endian.little);
      bmp[56] = 255;
      bmp[57] = 255;
      for (final source in [gif, bmp]) {
        final result = await AvatarPicker.normalize(source);
        expect(result.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final codec = await ui.instantiateImageCodec(result);
        final frame = await codec.getNextFrame();
        expect(frame.image.height, 1);
        frame.image.dispose();
        codec.dispose();
      }
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '$platform camera cancellation and errors are surfaced without a fallback upload',
      () async {
        const channel = MethodChannel('gemsnote/avatar_camera');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          messenger.setMockMethodCallHandler(channel, null);
        });
        var mode = 'cancel';
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'capture');
          if (mode == 'cancel') return null;
          if (mode == 'fail') throw PlatformException(code: 'noCamera');
          return File('assets/images/gemsnote_s.png').readAsBytesSync();
        });
        final picker = AvatarPicker();
        expect(picker.cameraSupported, isTrue);
        expect(await picker.capture(), isNull);
        mode = 'fail';
        await expectLater(picker.capture(), throwsA(isA<PlatformException>()));
        mode = 'ok';
        expect(await picker.capture(), isNotNull);
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        expect(picker.cameraSupported, isFalse);
        await expectLater(picker.capture(), throwsUnsupportedError);
      },
    );
  }
  testWidgets('cancel crop returns no image and never uploads', (tester) async {
    Uint8List? result;
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<Uint8List>(
                context: context,
                builder: (_) => AvatarCropDialog(
                  bytes: File('assets/images/gemsnote_s.png').readAsBytesSync(),
                ),
              );
              finished = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(result, isNull);
  });
}
