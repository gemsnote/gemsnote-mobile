import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/notebook.dart';
import '../domain/models/notebook_tree.dart';
import '../repositories/auth_repository.dart';
import 'notebook_target_picker.dart';

class MoveNotebookDialog extends StatefulWidget {
  const MoveNotebookDialog({
    required this.repository,
    required this.session,
    required this.notebook,
    super.key,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Notebook notebook;

  @override
  State<MoveNotebookDialog> createState() => _MoveNotebookDialogState();
}

class _MoveNotebookDialogState extends State<MoveNotebookDialog> {
  late Future<List<Notebook>> _notebooks;
  String? _parent;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _notebooks = widget.repository.notebooks(widget.session.account.cacheKey);
  }

  Future<void> _move() async {
    if (_busy || _parent == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.queueNotebookMove(
        widget.session,
        widget.notebook.notebookId,
        _parent!,
      );
      if (mounted) Navigator.pop(context, _parent);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = trNow(context, 'm0164', [error]);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0165')),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(context, 'm0166')),
            Flexible(
              child: SizedBox(
                height: 280,
                child: FutureBuilder<List<Notebook>>(
                  future: _notebooks,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return TextButton(
                        onPressed: () => setState(() {
                          _notebooks = widget.repository.notebooks(
                            widget.session.account.cacheKey,
                          );
                        }),
                        child: Text(tr(context, 'm0167')),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final notebooks = snapshot.data!;
                    return NotebookTargetPicker(
                      notebooks: notebooks,
                      selected: _parent,
                      enabled: !_busy,
                      allowRoot: true,
                      canSelect: (id) =>
                          id != widget.notebook.parentNotebookId &&
                          canMoveNotebook(
                            notebooks,
                            widget.notebook.notebookId,
                            id,
                          ),
                      onSelected: (id) => setState(() => _parent = id),
                    );
                  },
                ),
              ),
            ),
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
          onPressed: _busy || _parent == null ? null : _move,
          child: Text(tr(context, 'm0168')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
