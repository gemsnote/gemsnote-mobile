import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../services/note_image_picker.dart';

class NoteImageUploadDialog extends StatefulWidget {
  const NoteImageUploadDialog({
    required this.image,
    required this.upload,
    super.key,
  });
  final NoteImageUpload image;
  final Future<String> Function() upload;
  @override
  State<NoteImageUploadDialog> createState() => _NoteImageUploadDialogState();
}

class _NoteImageUploadDialogState extends State<NoteImageUploadDialog> {
  bool _busy = false;
  bool _attempted = false;
  String? _error;
  Future<void> _upload() async {
    if (_busy || _attempted) return;
    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
    });
    try {
      final reference = await widget.upload();
      if (mounted) Navigator.of(context).pop(reference);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0261', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0262')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.memory(widget.image.bytes, height: 140, fit: BoxFit.contain),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: _busy || _attempted ? null : _upload,
          child: Text(tr(context, 'm0264')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_attempted ? tr(context, 'm0010') : tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
