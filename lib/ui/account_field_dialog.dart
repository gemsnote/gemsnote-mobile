import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

class AccountFieldDialog extends StatefulWidget {
  const AccountFieldDialog({
    super.key,
    required this.value,
    required this.save,
    this.emailChange = false,
  });
  final String value;
  final bool emailChange;
  final Future<void> Function(String password, String value) save;
  @override
  State<AccountFieldDialog> createState() => _AccountFieldDialogState();
}

class _AccountFieldDialogState extends State<AccountFieldDialog> {
  late final _value = TextEditingController(text: widget.value);
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _value.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_value.text.trim().isEmpty ||
        (widget.emailChange && _password.text.isEmpty)) {
      setState(() => _error = trNow(context, 'm0012'));
      return;
    }
    if (widget.emailChange &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_value.text.trim())) {
      setState(() => _error = trNow(context, 'm0013'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(_password.text, _value.text.trim());
      _password.clear();
      if (mounted) Navigator.pop(context, true);
    } on Object {
      _password.clear();
      if (mounted) {
        setState(
          () => _error = widget.emailChange
              ? trNow(context, 'm0014')
              : trNow(context, 'm0015'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        widget.emailChange ? tr(context, 'm0016') : tr(context, 'm0017'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.emailChange) ...[
              Text(tr(context, 'm0019')),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: tr(context, 'm0021')),
              ),
            ],
            TextField(
              controller: _value,
              enabled: !_busy,
              keyboardType: widget.emailChange
                  ? TextInputType.emailAddress
                  : TextInputType.text,
              decoration: InputDecoration(
                labelText: widget.emailChange
                    ? tr(context, 'm0022')
                    : tr(context, 'm0023'),
              ),
            ),
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
          child: Text(
            widget.emailChange ? tr(context, 'm0024') : tr(context, 'm0025'),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
