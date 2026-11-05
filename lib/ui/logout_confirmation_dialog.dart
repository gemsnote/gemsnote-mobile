import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

Future<bool> confirmUnsyncedLogout(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, 'm0157')),
        content: Text(trNow(context, 'm0158')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0159')),
          ),
        ],
      ),
    ) ??
    false;
