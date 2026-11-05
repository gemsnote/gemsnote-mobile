import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/file_cache_usage.dart';

class FileCacheDialog extends StatefulWidget {
  const FileCacheDialog({
    super.key,
    required this.accountLabel,
    required this.load,
    required this.clear,
  });
  final String accountLabel;
  final Future<FileCacheUsage> Function() load;
  final Future<void> Function() clear;

  @override
  State<FileCacheDialog> createState() => _FileCacheDialogState();
}

class _FileCacheDialogState extends State<FileCacheDialog> {
  FileCacheUsage? _usage;
  bool _busy = true;
  bool _confirming = false;
  bool _cleared = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final usage = await widget.load();
      if (mounted) setState(() => _usage = usage);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0123'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy || !_confirming) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.clear();
      if (mounted) {
        setState(() {
          _usage = const FileCacheUsage(files: 0, bytes: 0);
          _cleared = true;
          _confirming = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0124'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0125')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.accountLabel),
            const SizedBox(height: 12),
            if (_usage != null)
              Text(tr(context, 'm0126', [_usage!.files, _usage!.sizeLabel])),
            if (_usage != null && _usage!.pendingDownloads > 0)
              Text(tr(context, 'm0127', [_usage!.pendingDownloads])),
            Text(tr(context, 'm0128')),
            const SizedBox(height: 8),
            Text(tr(context, 'm0129')),
            if (_confirming) Text(tr(context, 'm0130')),
            if (_cleared) Text(tr(context, 'm0131')),
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
        if (_usage == null && !_busy)
          TextButton(onPressed: _load, child: Text(tr(context, 'm0109'))),
        if (_usage != null &&
            (_usage!.files > 0 || _usage!.pendingDownloads > 0))
          FilledButton(
            onPressed: _busy
                ? null
                : _confirming
                ? _clear
                : () => setState(() => _confirming = true),
            child: Text(
              _confirming ? tr(context, 'm0132') : tr(context, 'm0133'),
            ),
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  if (_confirming) {
                    setState(() {
                      _confirming = false;
                      _error = null;
                    });
                  } else {
                    Navigator.pop(context);
                  }
                },
          child: Text(
            _confirming ? tr(context, 'm0026') : tr(context, 'm0010'),
          ),
        ),
      ],
    ),
  );
}
