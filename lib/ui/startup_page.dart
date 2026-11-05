import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// Contains no account data and can also cover session/lock initialization.
class StartupPage extends StatelessWidget {
  const StartupPage({super.key, this.errorKey, this.onRetry});

  final String? errorKey;
  final VoidCallback? onRetry;
  static const background = Color(0xff173d38);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background,
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gemsnote_s.png',
                width: 96,
                height: 96,
              ),
              const SizedBox(height: 20),
              Text(
                tr(context, 'm0141'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(context, 'm0003'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xffd5e1d9)),
              ),
              const SizedBox(height: 28),
              if (errorKey == null) ...[
                const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xffd5e1d9),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  tr(context, 'startupLoading'),
                  style: const TextStyle(color: Color(0xffd5e1d9)),
                ),
              ] else ...[
                Text(
                  tr(context, errorKey!),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(tr(context, 'm0006')),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
