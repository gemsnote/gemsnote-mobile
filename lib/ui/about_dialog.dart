import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/api/api2_client.dart';

class MobileAboutDialog extends StatefulWidget {
  const MobileAboutDialog({super.key, this.loadPackageInfo});

  final Future<PackageInfo> Function()? loadPackageInfo;

  @override
  State<MobileAboutDialog> createState() => _MobileAboutDialogState();
}

class _MobileAboutDialogState extends State<MobileAboutDialog> {
  late Future<PackageInfo> _info = _load();

  Future<PackageInfo> _load() async =>
      await (widget.loadPackageInfo?.call() ?? PackageInfo.fromPlatform())
          .timeout(const Duration(seconds: 5));

  String _value(String value) =>
      value.trim().isEmpty ? trNow(context, 'm0001') : value;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, 'm0002')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Image.asset(
              'assets/images/gemsnote_s.png',
              width: 64,
              height: 64,
            ),
          ),
          const SizedBox(height: 16),
          const Text('Gemsnote Mobile'),
          Text(tr(context, 'm0003')),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _info,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Text(tr(context, 'm0004'));
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'm0005')),
                    TextButton(
                      onPressed: () => setState(() {
                        _info = _load();
                      }),
                      child: Text(tr(context, 'm0006')),
                    ),
                  ],
                );
              }
              final info = snapshot.data!;
              return SelectableText(
                tr(context, 'm0007', [
                  _value(info.version),
                  _value(info.buildNumber),
                ]),
              );
            },
          ),
          Text(tr(context, 'm0008', [Api2Client.clientVersion])),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, 'm0010')),
      ),
    ],
  );
}
