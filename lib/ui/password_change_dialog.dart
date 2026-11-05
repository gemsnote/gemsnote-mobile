import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

class PasswordChangeDialog extends StatefulWidget {
  const PasswordChangeDialog({
    super.key,
    required this.identity,
    required this.save,
  });
  final String identity;
  final Future<void> Function(
    String identity,
    String oldPassword,
    String password,
  )
  save;
  @override
  State<PasswordChangeDialog> createState() => _PasswordChangeDialogState();
}

class _PasswordChangeDialogState extends State<PasswordChangeDialog> {
  late final _identity = TextEditingController(text: widget.identity);
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  void _clearPasswords() {
    _old.clear();
    _new.clear();
    _confirm.clear();
  }

  @override
  void dispose() {
    _identity.dispose();
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_identity.text.trim().isEmpty ||
        _old.text.isEmpty ||
        _new.text.isEmpty) {
      setState(() => _error = trNow(context, 'm0012'));
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = trNow(context, 'm0338'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(_identity.text.trim(), _old.text, _new.text);
      _clearPasswords();
      if (mounted) Navigator.pop(context, true);
    } on Object {
      _clearPasswords();
      if (mounted) {
        setState(() => _error = trNow(context, 'm0339'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _password(TextEditingController controller, String label) => TextField(
    controller: controller,
    enabled: !_busy,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(labelText: label),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'm0046')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(context, 'm0340')),
            TextField(
              controller: _identity,
              enabled: !_busy,
              decoration: InputDecoration(labelText: tr(context, 'm0020')),
            ),
            _password(_old, tr(context, 'm0021')),
            _password(_new, tr(context, 'm0341')),
            _password(_confirm, tr(context, 'm0342')),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                trMessage(context, _error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(tr(context, 'm0343')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
