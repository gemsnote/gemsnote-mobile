import 'package:flutter/material.dart';

import '../domain/models/notebook.dart';
import '../domain/models/notebook_conflict.dart';
import '../l10n/app_strings.dart';
import '../repositories/auth_repository.dart';

class NotebookConflictDialog extends StatefulWidget {
  const NotebookConflictDialog({
    super.key,
    required this.repository,
    required this.session,
    required this.notebook,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Notebook notebook;
  @override
  State<NotebookConflictDialog> createState() => _NotebookConflictDialogState();
}

class _NotebookConflictDialogState extends State<NotebookConflictDialog> {
  NotebookConflictSnapshot? _reviewed;
  bool _busy = false;
  String? _error;
  String _message(Object error) {
    final key = error is StateError ? error.message : '';
    return switch (key) {
      'notebookConflictAccount' ||
      'notebookConflictLocalChanged' ||
      'notebookConflictRemoteUnavailable' ||
      'notebookConflictInvalidSnapshot' ||
      'notebookConflictRemoteChanged' ||
      'notebookConflictHierarchy' => trNow(context, key),
      _ => trNow(context, 'notebookReviewFailed', [error]),
    };
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _reviewed = null;
    });
    try {
      final reviewed = await widget.repository.reviewNotebookConflict(
        widget.session,
        widget.notebook.notebookId,
      );
      if (mounted) setState(() => _reviewed = reviewed);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolve(bool keepLocal) async {
    if (_busy || _reviewed == null) return;
    final reviewed = _reviewed!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          tr(context, keepLocal ? 'notebookKeepLocal' : 'notebookUseRemote'),
        ),
        content: Text(
          tr(
            context,
            keepLocal ? 'notebookKeepConfirm' : 'notebookRemoteConfirm',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'm0025')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.resolveNotebookConflict(
        widget.session,
        reviewed,
        keepLocal: keepLocal,
      );
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _reviewed = null;
          _error = _message(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reviewed = _reviewed;
    final local = reviewed?.local ?? widget.notebook;
    Widget details(String label, Notebook book, {bool remote = false}) {
      final parent = book.parentNotebookId.isEmpty
          ? tr(context, 'notebookRoot')
          : (remote
                    ? reviewed?.remoteBooks
                          .where((n) => n.notebookId == book.parentNotebookId)
                          .firstOrNull
                          ?.title
                    : null) ??
                book.parentNotebookId;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            SelectableText(book.title),
            Text(tr(context, 'notebookReviewLocation', [parent])),
            Text(tr(context, 'notebookReviewVersion', [book.usn])),
          ],
        ),
      );
    }

    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(tr(context, 'notebookReviewTitle')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr(context, 'notebookReviewIntro')),
              details(tr(context, 'notebookLocalVersion'), local),
              if (reviewed != null)
                details(
                  tr(context, 'notebookRemoteVersion'),
                  reviewed.remote,
                  remote: true,
                ),
              if (_error != null)
                Text(
                  trMessage(context, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_busy) const LinearProgressIndicator(),
              OutlinedButton(
                onPressed: _busy ? null : _load,
                child: Text(tr(context, 'notebookReviewFetch')),
              ),
              if (reviewed != null) ...[
                FilledButton(
                  onPressed: _busy ? null : () => _resolve(true),
                  child: Text(tr(context, 'notebookKeepLocal')),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _resolve(false),
                  child: Text(tr(context, 'notebookUseRemote')),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(tr(context, 'm0026')),
          ),
        ],
      ),
    );
  }
}
