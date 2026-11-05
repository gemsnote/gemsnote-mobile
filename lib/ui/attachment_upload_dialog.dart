import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/attachment_upload.dart';

class AttachmentUploadDialog extends StatefulWidget {
  const AttachmentUploadDialog({
    required this.file,
    required this.upload,
    super.key,
  });
  final AttachmentUpload file;
  final Future<bool> Function() upload;
  @override
  State<AttachmentUploadDialog> createState() => _AttachmentUploadDialogState();
}

class _AttachmentUploadDialogState extends State<AttachmentUploadDialog> {
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
      final refreshed = await widget.upload();
      if (mounted) Navigator.of(context).pop(refreshed);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0077', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0070')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr(context, 'm0078', [widget.file.name, widget.file.bytes.length]),
          ),
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
          child: Text(tr(context, 'm0081')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
