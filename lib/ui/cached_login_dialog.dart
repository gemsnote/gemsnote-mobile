import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

Future<bool> chooseCachedLoginReset(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(trNow(context, 'm0091')),
          content: Text(trNow(context, 'm0092')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(trNow(context, 'm0093')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(trNow(context, 'm0094')),
            ),
          ],
        ),
      ),
    ) ??
    false;
