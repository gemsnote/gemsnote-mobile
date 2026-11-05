import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A cache-only avatar shared by the workspace and account screen.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, this.bytes, this.size = 36});
  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => Icon(Icons.account_circle, size: size);
    return Semantics(
      label: tr(context, 'm0011'),
      image: true,
      child: ClipOval(
        child: bytes == null
            ? placeholder()
            : Image.memory(
                bytes!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => placeholder(),
              ),
      ),
    );
  }
}
