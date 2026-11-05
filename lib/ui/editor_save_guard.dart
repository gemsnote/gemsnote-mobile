import '../l10n/app_strings.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A DOM snapshot must reach the serialized local save queue before leaving.
Future<bool> persistVisualEdit({
  required Future<String?> Function() read,
  required bool Function(String) accept,
  required Future<bool> Function() flush,
}) async {
  final value = await read();
  if (value != null && !accept(value)) return false;
  return flush();
}

class EditorSaveBanner extends StatefulWidget {
  const EditorSaveBanner({required this.error, required this.retry, super.key});
  final ValueListenable<String?> error;
  final Future<bool> Function() retry;

  @override
  State<EditorSaveBanner> createState() => _EditorSaveBannerState();
}

class _EditorSaveBannerState extends State<EditorSaveBanner> {
  bool _busy = false;
  String? _retryError;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _retryError = null;
    });
    try {
      final saved = await widget.retry();
      if (!saved && mounted && widget.error.value == null) {
        setState(() => _retryError = trNow(context, 'm0114'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _retryError = trNow(context, 'm0115', [error]));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: widget.error,
    builder: (_, error, _) => error == null && _retryError == null
        ? const SizedBox.shrink()
        : MaterialBanner(
            content: Text(error ?? _retryError!),
            actions: [
              TextButton(
                onPressed: _busy ? null : _retry,
                child: Text(
                  _busy ? tr(context, 'm0116') : tr(context, 'm0117'),
                ),
              ),
            ],
          ),
  );
}
