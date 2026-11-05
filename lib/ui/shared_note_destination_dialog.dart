import 'package:flutter/material.dart';

import '../domain/models/notebook.dart';
import '../l10n/app_strings.dart';
import 'notebook_target_picker.dart';

class SharedNoteDestination {
  const SharedNoteDestination(this.notebookId, this.copy);
  final String notebookId;
  final bool copy;
}

class SharedNoteDestinationDialog extends StatefulWidget {
  const SharedNoteDestinationDialog({super.key, required this.notebooks});
  final List<Notebook> notebooks;
  @override
  State<SharedNoteDestinationDialog> createState() =>
      _SharedNoteDestinationDialogState();
}

class _SharedNoteDestinationDialogState
    extends State<SharedNoteDestinationDialog> {
  String? _target;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, 'moveCopyShared')),
    content: SizedBox(
      width: 420,
      height: 340,
      child: NotebookTargetPicker(
        notebooks: widget.notebooks,
        onSelected: (value) => setState(() => _target = value),
        selected: _target,
      ),
    ),
    actions: [
      TextButton(
        onPressed: _target == null
            ? null
            : () => Navigator.pop(
                context,
                SharedNoteDestination(_target!, false),
              ),
        child: Text(tr(context, 'm0289')),
      ),
      TextButton(
        onPressed: _target == null
            ? null
            : () =>
                  Navigator.pop(context, SharedNoteDestination(_target!, true)),
        child: Text(tr(context, 'm0664')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, 'm0026')),
      ),
    ],
  );
}
