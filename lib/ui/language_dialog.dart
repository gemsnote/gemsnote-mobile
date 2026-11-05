import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../l10n/language_controller.dart';

class LanguageDialog extends StatefulWidget {
  const LanguageDialog({super.key});
  @override
  State<LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<LanguageDialog> {
  bool _busy = false;
  String? _error;
  Future<void> _choose(LanguageController controller, String value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await controller.choose(value);
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0545', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = LanguageScope.maybeOf(context)!;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(tr(context, 'languageTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(context, 'm0546')),
            for (final entry in {
              'system': tr(context, 'm0547'),
              'zh': tr(context, 'm0548'),
              'en': 'English',
            }.entries)
              ListTile(
                title: Text(entry.value),
                enabled: !_busy,
                trailing: controller.preference == entry.key
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => _choose(controller, entry.key),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                trMessage(context, _error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
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
