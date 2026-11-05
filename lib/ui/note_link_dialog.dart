import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../services/note_link_opener.dart';

class NoteLinkDialog extends StatefulWidget {
  const NoteLinkDialog({
    super.key,
    required this.href,
    required this.onCopy,
    this.opener,
  });
  final String href;
  final Future<void> Function() onCopy;
  final NoteLinkOpener? opener;

  @override
  State<NoteLinkDialog> createState() => _NoteLinkDialogState();
}

class _NoteLinkDialogState extends State<NoteLinkDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _open() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.opener ?? NoteLinkOpener()).open(widget.href);
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0265'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = externalNoteLink(widget.href);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(tr(context, 'm0112')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(widget.href),
              const SizedBox(height: 12),
              if (uri != null) ...[
                Text(tr(context, 'm0266', [uri.host])),
                Text(tr(context, 'm0267')),
              ] else
                Text(tr(context, 'm0268')),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  trMessage(context, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          if (uri != null)
            FilledButton(
              onPressed: _busy ? null : _open,
              child: Text(tr(context, 'm0269')),
            ),
          TextButton(
            onPressed: _busy ? null : widget.onCopy,
            child: Text(tr(context, 'm0270')),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(tr(context, 'm0010')),
          ),
        ],
      ),
    );
  }
}
