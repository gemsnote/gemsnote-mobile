import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gemsnote/services/attachment_opener.dart';

void main() => runApp(const MaterialApp(home: AttachmentOpenFixture()));

class AttachmentOpenFixture extends StatefulWidget {
  const AttachmentOpenFixture({super.key});

  @override
  State<AttachmentOpenFixture> createState() => _AttachmentOpenFixtureState();
}

class _AttachmentOpenFixtureState extends State<AttachmentOpenFixture> {
  static const run = String.fromEnvironment('ATTACHMENT_OPEN_RUN');
  String status = 'Ready';
  bool busy = false;

  Future<void> open(String kind) async {
    setState(() {
      busy = true;
      status = 'Running $kind';
    });
    try {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(run)) {
        throw StateError('Missing run');
      }
      await AttachmentOpener().open(
        kind == 'binary' ? '../open-$run-附件?.BIN' : 'open-$run-empty.bin',
        Uint8List.fromList(kind == 'binary' ? [0, 1, 127, 128, 255] : []),
      );
      status = 'Returned $kind';
    } catch (error) {
      status = 'FAIL $error';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Attachment open verification')),
    body: Column(
      children: [
        Text(status),
        for (final kind in ['binary', 'empty'])
          TextButton(
            onPressed: busy ? null : () => open(kind),
            child: Text('Open $kind'),
          ),
      ],
    ),
  );
}
