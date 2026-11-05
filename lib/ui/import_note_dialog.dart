import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../services/note_importer.dart';

class ImportNoteDialog extends StatefulWidget {
  const ImportNoteDialog({
    super.key,
    required this.onImport,
    this.importer,
    this.targetTitle,
  });
  final String? targetTitle;
  final Future<Note> Function(ImportedNote) onImport;
  final NoteImporter? importer;
  @override
  State<ImportNoteDialog> createState() => _ImportNoteDialogState();
}

class _ImportNoteDialogState extends State<ImportNoteDialog> {
  ImportedNote? _note;
  bool _busy = false;
  String? _error;
  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note =
          await (widget.importer ??
                  NoteImporter(strings: AppStrings.snapshot(context)))
              .pick();
      if (mounted && note != null) setState(() => _note = note);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0134', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy || _note == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = await widget.onImport(_note!);
      if (mounted) Navigator.pop(context, note);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0135', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0136')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.targetTitle != null)
              Text(tr(context, 'importTarget', [widget.targetTitle!])),
            Text(tr(context, 'm0137')),
            TextButton(
              onPressed: _busy ? null : _pick,
              child: Text(tr(context, 'm0138')),
            ),
            if (_note != null) ...[
              Text(_note!.title),
              if (_note!.warning != null)
                Text(trMessage(context, _note!.warning!)),
              if (_note!.bundle != null)
                Text(
                  tr(context, 'bundleImportInfo', [
                    _note!.bundle!.resources.length,
                  ]),
                ),
              Text(
                tr(context, 'm0139', [
                  _note!.isMarkdown ? "Markdown" : "HTML",
                  _note!.content.length,
                ]),
              ),
            ],
            if (_error != null)
              Text(
                trMessage(context, _error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _busy || _note == null ? null : _import,
          child: Text(tr(context, 'm0140')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
