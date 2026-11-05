import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/notebook.dart';
import '../repositories/auth_repository.dart';

class NotebookCreationDialog extends StatefulWidget {
  const NotebookCreationDialog({
    super.key,
    required this.repository,
    required this.session,
    required this.notebook,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Notebook notebook;
  @override
  State<NotebookCreationDialog> createState() => _NotebookCreationDialogState();
}

class _NotebookCreationDialogState extends State<NotebookCreationDialog> {
  bool _busy = true;
  String? _state, _error;
  List<Notebook>? _candidates;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await widget.repository.notebookCreationState(
        widget.session,
        widget.notebook.notebookId,
      );
      if (mounted) setState(() => _state = state);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0313', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lookup() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final candidates = await widget.repository.notebookCreationCandidates(
        widget.session,
        widget.notebook.notebookId,
      );
      if (mounted) setState(() => _candidates = candidates);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0314', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolve(Notebook? remote) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          remote == null ? trNow(context, 'm0315') : trNow(context, 'm0316'),
        ),
        content: Text(
          remote == null
              ? trNow(context, 'm0317')
              : trNow(context, 'm0318', [
                  widget.notebook.title,
                  remote.notebookId,
                ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0056')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (remote == null) {
        await widget.repository.retryNotebookCreation(
          widget.session,
          widget.notebook.notebookId,
        );
      } else {
        await widget.repository.confirmNotebookCreation(
          widget.session,
          widget.notebook.notebookId,
          remote,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0319', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0320')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.notebook.title),
              Text(
                _state == 'pending'
                    ? tr(context, 'm0321')
                    : _state == 'uncertain'
                    ? tr(context, 'm0322')
                    : _state == 'complete'
                    ? tr(context, 'm0323')
                    : tr(context, 'm0324'),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_candidates != null && _candidates!.isEmpty)
                Text(tr(context, 'm0325')),
              for (final candidate in _candidates ?? <Notebook>[])
                ListTile(
                  title: Text(candidate.title),
                  subtitle: Text(candidate.notebookId),
                  enabled: !_busy,
                  onTap: () => _resolve(candidate),
                ),
              if (_error != null)
                Text(
                  trMessage(context, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (_state == 'uncertain') ...[
          TextButton(
            onPressed: _busy ? null : _lookup,
            child: Text(tr(context, 'm0326')),
          ),
          TextButton(
            onPressed: _busy ? null : () => _resolve(null),
            child: Text(tr(context, 'm0073')),
          ),
        ],
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0010')),
        ),
      ],
    ),
  );
}
