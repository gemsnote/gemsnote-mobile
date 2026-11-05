import '../l10n/app_strings.dart';

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/avatar_picker.dart';

Rect avatarCropRect(Size size, Offset center, double zoom) {
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0 ||
      !center.dx.isFinite ||
      !center.dy.isFinite ||
      !zoom.isFinite ||
      zoom < 1 ||
      zoom > 4) {
    throw ArgumentError('Invalid crop');
  }
  final edge = math.min(size.width, size.height) / zoom;
  final x = (center.dx * size.width - edge / 2).clamp(0.0, size.width - edge);
  final y = (center.dy * size.height - edge / 2).clamp(0.0, size.height - edge);
  return Rect.fromLTWH(x, y, edge, edge);
}

Future<Uint8List> cropAvatar(ui.Image image, Rect source) async {
  if (source.isEmpty ||
      !source.isFinite ||
      source.left < 0 ||
      source.top < 0 ||
      source.right > image.width ||
      source.bottom > image.height ||
      (source.width - source.height).abs() > 0.001) {
    throw ArgumentError('Invalid crop bounds');
  }
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    source,
    const Rect.fromLTWH(0, 0, 256, 256),
    Paint()..filterQuality = FilterQuality.high,
  );
  final picture = recorder.endRecording();
  ui.Image? output;
  try {
    output = await picture.toImage(256, 256);
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('无法生成头像');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    output?.dispose();
    picture.dispose();
  }
}

class AvatarCropDialog extends StatefulWidget {
  const AvatarCropDialog({required this.bytes, super.key});
  final Uint8List bytes;
  @override
  State<AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<AvatarCropDialog> {
  ui.Image? _image;
  Offset _center = const Offset(.5, .5);
  double _zoom = 1;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    ui.Codec? codec;
    try {
      final normalized = await AvatarPicker.normalize(
        widget.bytes,
        maxDimension: 1024,
      );
      codec = await ui.instantiateImageCodec(normalized);
      final image = (await codec.getNextFrame()).image;
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0082', [error]));
    } finally {
      codec?.dispose();
    }
  }

  Rect get _rect => avatarCropRect(
    Size(_image!.width.toDouble(), _image!.height.toDouble()),
    _center,
    _zoom,
  );
  Future<void> _finish() async {
    if (_image == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await cropAvatar(_image!, _rect);
      if (mounted) {
        setState(() => _busy = false);
        Navigator.pop(context, bytes);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0083', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0084')),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr(context, 'm0085')),
              const SizedBox(height: 12),
              if (_image == null && _error == null)
                const CircularProgressIndicator(),
              if (_image != null)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final edge = math.min(280.0, constraints.maxWidth);
                    return GestureDetector(
                      onPanUpdate: _busy
                          ? null
                          : (details) {
                              final rect = _rect;
                              final x =
                                  (rect.center.dx -
                                      details.delta.dx * rect.width / edge) /
                                  _image!.width;
                              final y =
                                  (rect.center.dy -
                                      details.delta.dy * rect.height / edge) /
                                  _image!.height;
                              final clamped = avatarCropRect(
                                Size(
                                  _image!.width.toDouble(),
                                  _image!.height.toDouble(),
                                ),
                                Offset(x, y),
                                _zoom,
                              );
                              setState(
                                () => _center = Offset(
                                  clamped.center.dx / _image!.width,
                                  clamped.center.dy / _image!.height,
                                ),
                              );
                            },
                      child: SizedBox(
                        width: edge,
                        height: edge,
                        child: CustomPaint(
                          painter: _CropPainter(_image!, _rect),
                        ),
                      ),
                    );
                  },
                ),
              Slider(
                value: _zoom,
                min: 1,
                max: 4,
                label: '${_zoom.toStringAsFixed(1)}×',
                onChanged: _image == null || _busy
                    ? null
                    : (value) => setState(() => _zoom = value),
              ),
              if (_error != null) Text(trMessage(context, _error!)),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0026')),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _center = const Offset(.5, .5);
                  _zoom = 1;
                }),
          child: Text(tr(context, 'm0086')),
        ),
        FilledButton(
          onPressed: _image == null || _busy ? null : _finish,
          child: Text(tr(context, 'm0087')),
        ),
      ],
    ),
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.source);
  final ui.Image image;
  final Rect source;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xffeeeeee), BlendMode.src);
    canvas.drawImageRect(
      image,
      source,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.source != source;
}
