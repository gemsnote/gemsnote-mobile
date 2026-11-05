import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

/// Bounded, attribute-free HTML supported by the offline visual editor.
String buildEditorTable(int rows, int columns) {
  if (rows < 1 || rows > 20 || columns < 1 || columns > 10) {
    throw ArgumentError('Table dimensions out of range');
  }
  final row = '<tr>${List.filled(columns, '<td><br></td>').join()}</tr>';
  return '<table><tbody>${List.filled(rows, row).join()}</tbody></table><p><br></p>';
}

class EditorTableDialog extends StatefulWidget {
  const EditorTableDialog({super.key});

  @override
  State<EditorTableDialog> createState() => _EditorTableDialogState();
}

class _EditorTableDialogState extends State<EditorTableDialog> {
  final _rows = TextEditingController(text: '3');
  final _columns = TextEditingController(text: '3');
  String? _error;

  @override
  void dispose() {
    _rows.dispose();
    _columns.dispose();
    super.dispose();
  }

  void _submit() {
    final rows = int.tryParse(_rows.text.trim());
    final columns = int.tryParse(_columns.text.trim());
    if (rows == null ||
        columns == null ||
        rows < 1 ||
        rows > 20 ||
        columns < 1 ||
        columns > 10) {
      setState(() => _error = trNow(context, 'm0118'));
      return;
    }
    Navigator.of(context).pop(buildEditorTable(rows, columns));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, 'm0119')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _rows,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr(context, 'm0120')),
          ),
          TextField(
            controller: _columns,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(labelText: tr(context, 'm0121')),
          ),
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
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr(context, 'm0026')),
      ),
      FilledButton(onPressed: _submit, child: Text(tr(context, 'm0122'))),
    ],
  );
}
