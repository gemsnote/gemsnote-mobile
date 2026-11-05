import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

class CreateTagDialog extends StatefulWidget {
  const CreateTagDialog({required this.onCreate, super.key});

  final Future<void> Function(String) onCreate;

  @override
  State<CreateTagDialog> createState() => _CreateTagDialogState();
}

class _CreateTagDialogState extends State<CreateTagDialog> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || !_name.value.composing.isCollapsed) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = trNow(context, 'm0099'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(name);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = trNow(context, 'm0100', [error]));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0101')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(context, 'm0102')),
            TextField(
              controller: _name,
              enabled: !_busy,
              autofocus: true,
              maxLength: 200,
              decoration: InputDecoration(labelText: tr(context, 'm0103')),
              onSubmitted: (_) => _create(),
            ),
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
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(tr(context, 'm0026')),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: Text(tr(context, 'm0104')),
        ),
      ],
    ),
  );
}
