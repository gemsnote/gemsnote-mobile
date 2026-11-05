import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/default_editor.dart';

class DefaultEditorDialog extends StatefulWidget {
  const DefaultEditorDialog({
    super.key,
    required this.load,
    required this.save,
  });
  final Future<DefaultEditor> Function() load;
  final Future<void> Function(DefaultEditor) save;

  @override
  State<DefaultEditorDialog> createState() => _DefaultEditorDialogState();
}

class _DefaultEditorDialogState extends State<DefaultEditorDialog> {
  DefaultEditor? _selected;
  bool _busy = true;
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
      final editor = await widget.load();
      if (mounted) setState(() => _selected = editor);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0105', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _selected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(_selected!);
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0106', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0107')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tr(context, 'm0108')),
          const SizedBox(height: 16),
          if (_selected != null)
            SegmentedButton<DefaultEditor>(
              segments: [
                for (final editor in DefaultEditor.values)
                  ButtonSegment(
                    value: editor,
                    label: Text(trLabel(context, editor.label)),
                  ),
              ],
              selected: {_selected!},
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() => _selected = value.single),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_selected == null && !_busy)
            TextButton(onPressed: _load, child: Text(tr(context, 'm0109'))),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: _busy || _selected == null ? null : _save,
          child: Text(tr(context, 'm0025')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
