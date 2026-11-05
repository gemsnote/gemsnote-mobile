import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import 'visual_html_policy.dart';

class EditorLinkDialog extends StatefulWidget {
  const EditorLinkDialog({super.key});

  @override
  State<EditorLinkDialog> createState() => _EditorLinkDialogState();
}

class _EditorLinkDialogState extends State<EditorLinkDialog> {
  final _url = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _url.text.trim();
    if (!isSafeEditorLink(value)) {
      setState(() => _error = trNow(context, 'm0110'));
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, 'm0111')),
    content: TextField(
      controller: _url,
      autofocus: true,
      keyboardType: TextInputType.url,
      autocorrect: false,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: tr(context, 'm0112'),
        hintText: 'https://',
        errorText: _error,
        errorMaxLines: 3,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr(context, 'm0026')),
      ),
      FilledButton(onPressed: _submit, child: Text(tr(context, 'm0113'))),
    ],
  );
}
