import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

typedef CachedImageLoader = Future<Uint8List?> Function(Uri uri);

class CachedMarkdownImage extends StatefulWidget {
  const CachedMarkdownImage({
    super.key,
    required this.uri,
    required this.alt,
    required this.load,
    this.download,
  });
  final Uri uri;
  final String? alt;
  final CachedImageLoader load;
  final Future<Uint8List> Function()? download;
  @override
  State<CachedMarkdownImage> createState() => _CachedMarkdownImageState();
}

class _CachedMarkdownImageState extends State<CachedMarkdownImage> {
  late Future<Uint8List?> _bytes;
  bool _downloading = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _bytes = widget.load(widget.uri);
  }

  @override
  void didUpdateWidget(CachedMarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.load != widget.load) {
      _generation++;
      _downloading = false;
      _error = null;
      _bytes = widget.load(widget.uri);
    }
  }

  Future<void> _download() async {
    if (_downloading || widget.download == null) return;
    final generation = _generation;
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final bytes = await widget.download!();
      if (mounted && generation == _generation) {
        setState(() {
          _bytes = Future.value(bytes);
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = trNow(context, 'm0095', [error]));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _downloading = false);
      }
    }
  }

  Widget _placeholder() => Container(
    padding: const EdgeInsets.all(12),
    color: const Color(0xffebe8dc),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          trNow(context, 'm0096', [
            widget.alt == null || widget.alt!.isEmpty ? '' : '：${widget.alt}',
          ]),
        ),
        if (_error != null)
          Text(
            trMessage(context, _error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (widget.download != null)
          TextButton.icon(
            onPressed: _downloading ? null : _download,
            icon: const Icon(Icons.download_outlined),
            label: Text(
              _downloading ? trNow(context, 'm0097') : trNow(context, 'm0098'),
            ),
          ),
      ],
    ),
  );

  Future<void> _preview(Uint8List bytes) => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.alt == null || widget.alt!.isEmpty
                ? tr(dialogContext, 'm0369')
                : widget.alt!,
          ),
          leading: IconButton(
            tooltip: tr(dialogContext, 'm0010'),
            onPressed: () => Navigator.pop(dialogContext),
            icon: const Icon(Icons.close),
          ),
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Image.memory(
              bytes,
              semanticLabel: widget.alt,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Text(tr(dialogContext, 'm0247')),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (_, snapshot) {
      if (snapshot.connectionState != ConnectionState.done ||
          snapshot.hasError ||
          snapshot.data == null) {
        return _placeholder();
      }
      return Semantics(
        button: true,
        label: tr(context, 'm0369'),
        child: Tooltip(
          message: tr(context, 'm0369'),
          child: GestureDetector(
            onTap: () => _preview(snapshot.data!),
            child: Image(
              image: ResizeImage(
                MemoryImage(snapshot.data!),
                width: 2048,
                height: 2048,
                policy: ResizeImagePolicy.fit,
              ),
              semanticLabel: widget.alt,
              frameBuilder: (_, child, frame, _) =>
                  frame == null ? _placeholder() : child,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _placeholder(),
            ),
          ),
        ),
      );
    },
  );
}
