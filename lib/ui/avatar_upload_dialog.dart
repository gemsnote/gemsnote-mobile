import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

class AvatarUploadDialog extends StatefulWidget {
  const AvatarUploadDialog({
    super.key,
    required this.bytes,
    required this.upload,
  });
  final Uint8List bytes;
  final Future<void> Function() upload;
  @override
  State<AvatarUploadDialog> createState() => _AvatarUploadDialogState();
}

class _AvatarUploadDialogState extends State<AvatarUploadDialog> {
  bool _busy = false;
  String? _error;
  Future<void> _upload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.upload();
      if (mounted) Navigator.pop(context, true);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0089'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0038')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.memory(widget.bytes, width: 96, height: 96),
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
          onPressed: _busy ? null : _upload,
          child: Text(tr(context, 'm0081')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
