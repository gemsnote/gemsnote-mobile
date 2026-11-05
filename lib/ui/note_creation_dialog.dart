import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../domain/models/note_creation_review.dart';
import '../l10n/app_strings.dart';

class NoteCreationDialog extends StatefulWidget {
  const NoteCreationDialog({
    super.key,
    required this.load,
    required this.recover,
  });
  final Future<NoteCreationReview> Function() load;
  final Future<void> Function(NoteCreationReview) recover;
  @override
  State<NoteCreationDialog> createState() => _NoteCreationDialogState();
}

class _NoteCreationDialogState extends State<NoteCreationDialog> {
  NoteCreationReview? _review;
  bool _busy = false;
  bool _confirming = false;
  String? _error;

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _review = null;
    });
    try {
      final review = await widget.load();
      if (mounted) setState(() => _review = review);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
  }

  String _message(Object error) {
    final key = error is StateError ? error.message : '';
    return switch (key) {
      'noteCreationAccount' ||
      'noteCreationLocalChanged' ||
      'noteCreationRemoteChanged' ||
      'noteCreationUnavailable' ||
      'noteCreationTags' => trNow(context, key),
      _ => trNow(context, 'noteCreationFailed', [error]),
    };
  }

  Future<void> _recover() async {
    final review = _review;
    if (_busy || review == null) return;
    setState(() {
      _busy = true;
      _confirming = true;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(tr(context, 'noteCreationKeep')),
          content: Text(tr(context, 'noteCreationConfirm')),
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
      setState(() => _confirming = false);
      await widget.recover(review);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _review = null;
          _error = _message(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
  }

  Widget _details(String title, Note note) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        SelectableText(note.title),
        Text(
          tr(context, 'noteCreationDetails', [
            note.notebookId,
            note.usn,
            note.isMarkdown ? 'Markdown' : 'HTML',
            note.tags.join(', '),
            tr(
              context,
              note.isStarred ? 'noteCreationStarred' : 'noteCreationUnstarred',
            ),
          ]),
        ),
        ExpansionTile(
          title: Text(tr(context, 'noteCreationSource')),
          children: [
            SizedBox(
              height: 200,
              child: SingleChildScrollView(child: SelectableText(note.content)),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(tr(context, 'noteCreationTitle')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(context, 'noteCreationIntro')),
            if (_review != null) ...[
              _details(tr(context, 'notebookLocalVersion'), _review!.local),
              _details(tr(context, 'notebookRemoteVersion'), _review!.remote),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_busy && !_confirming) const LinearProgressIndicator(),
            OutlinedButton(
              onPressed: _busy ? null : _load,
              child: Text(tr(context, 'notebookReviewFetch')),
            ),
            if (_review != null)
              FilledButton(
                onPressed: _busy ? null : _recover,
                child: Text(tr(context, 'noteCreationKeep')),
              ),
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
