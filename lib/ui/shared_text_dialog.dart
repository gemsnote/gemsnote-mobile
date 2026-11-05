import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../domain/models/notebook.dart';
import '../services/shared_text_inbox.dart';
import 'notebook_target_picker.dart';

class SharedTextDialog extends StatefulWidget {
  const SharedTextDialog({
    super.key,
    required this.source,
    required this.notebooks,
    required this.accountLabel,
    required this.canImport,
    required this.onImport,
    required this.onAcknowledge,
  });
  final SharedText source;
  final List<Notebook> notebooks;
  final String accountLabel;
  final bool canImport;
  final Future<Note> Function(SharedText source, String notebookId) onImport;
  final Future<void> Function() onAcknowledge;

  @override
  State<SharedTextDialog> createState() => _SharedTextDialogState();
}

class _SharedTextDialogState extends State<SharedTextDialog> {
  late final _title = TextEditingController(text: widget.source.suggestedTitle);
  late final _body = TextEditingController(text: widget.source.text);
  String? _notebook;
  bool _busy = false;
  Note? _imported;
  String? _error;
  late bool _asImage = widget.source.resourceKind == 'image';

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    if (_busy || !widget.canImport || _notebook == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _imported ??= await widget.onImport(
        SharedText(
          id: widget.source.id,
          title: _title.text,
          text: _body.text,
          accountKey: widget.source.accountKey,
          resourceKind: widget.source.hasResource
              ? (_asImage ? 'image' : 'attachment')
              : '',
          resourceName: widget.source.resourceName,
          resourceSize: widget.source.resourceSize,
        ),
        _notebook!,
      );
      await widget.onAcknowledge();
      if (mounted) Navigator.pop(context, _imported);
    } on Object catch (failure) {
      if (mounted) {
        setState(
          () => _error = _imported == null
              ? trNow(context, 'm0135', [failure])
              : trNow(context, 'm0383', [failure]),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard() async {
    if (_busy || _imported != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, 'm0384')),
        content: Text(trNow(context, 'm0385')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0386')),
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
      await widget.onAcknowledge();
      if (mounted) Navigator.pop(context);
    } on Object catch (failure) {
      if (mounted) setState(() => _error = trNow(context, 'm0387', [failure]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        widget.source.hasResource ? tr(context, 'm0388') : tr(context, 'm0389'),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, 'm0390', [widget.accountLabel])),
              Text(tr(context, 'm0391')),
              if (widget.source.hasResource) ...[
                Text(
                  tr(context, 'm0392', [
                    widget.source.resourceName,
                    widget.source.resourceSize,
                  ]),
                ),
                Text(tr(context, 'm0393')),
                if (widget.source.resourceKind == 'image')
                  CheckboxListTile(
                    title: Text(tr(context, 'm0394')),
                    subtitle: Text(tr(context, 'm0395')),
                    value: _asImage,
                    onChanged: _busy || _imported != null || !widget.canImport
                        ? null
                        : (value) => setState(() => _asImage = value ?? false),
                  ),
              ],
              if (!widget.canImport) Text(tr(context, 'm0396')),
              TextField(
                controller: _title,
                enabled: !_busy && _imported == null && widget.canImport,
                decoration: InputDecoration(labelText: tr(context, 'm0185')),
                maxLength: 200,
              ),
              TextField(
                controller: _body,
                enabled: !_busy && _imported == null && widget.canImport,
                decoration: InputDecoration(labelText: tr(context, 'm0397')),
                minLines: 2,
                maxLines: 5,
              ),
              if (widget.notebooks.isEmpty) Text(tr(context, 'm0398')),
              SizedBox(
                height: 210,
                child: NotebookTargetPicker(
                  notebooks: widget.notebooks,
                  selected: _notebook,
                  enabled: !_busy && _imported == null && widget.canImport,
                  onSelected: (id) => setState(() => _notebook = id),
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
      ),
      actions: [
        TextButton(
          onPressed: _busy || _imported != null ? null : _discard,
          child: Text(tr(context, 'm0386')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, _imported),
          child: Text(tr(context, 'm0399')),
        ),
        FilledButton(
          onPressed: _busy || _notebook == null || !widget.canImport
              ? null
              : _import,
          child: Text(
            _imported == null ? tr(context, 'm0400') : tr(context, 'm0401'),
          ),
        ),
      ],
    ),
  );
}
