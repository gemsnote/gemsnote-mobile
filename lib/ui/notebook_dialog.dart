import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/notebook.dart';
import '../repositories/auth_repository.dart';

class NotebookDialog extends StatefulWidget {
  const NotebookDialog({
    super.key,
    required this.repository,
    required this.session,
    this.existing,
    this.parentNotebookId = '',
  });

  final AuthRepository repository;
  final StoredSession session;
  final Notebook? existing;
  final String parentNotebookId;

  @override
  State<NotebookDialog> createState() => _NotebookDialogState();
}

class _NotebookDialogState extends State<NotebookDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = trNow(context, 'm0327'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.existing != null) {
        await widget.repository.queueNotebookRename(
          widget.session,
          widget.existing!.notebookId,
          _title.text,
        );
      } else {
        await widget.repository.createOfflineNotebook(
          widget.session,
          _title.text,
          widget.parentNotebookId,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = trNow(context, 'm0306', [error]);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        widget.existing != null
            ? tr(context, 'm0328')
            : widget.parentNotebookId.isEmpty
            ? tr(context, 'm0329')
            : tr(context, 'm0330'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            enabled: !_busy,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: tr(context, 'm0331'),
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          Text(tr(context, 'm0332')),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0026')),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(tr(context, 'm0025')),
        ),
      ],
    ),
  );
}
