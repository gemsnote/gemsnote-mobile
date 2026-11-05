import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/services/attachment_sharer.dart';
import 'package:gemsnote/services/note_sharer.dart';

void main() => runApp(const MaterialApp(home: OutboundFixture()));

class OutboundFixture extends StatefulWidget {
  const OutboundFixture({super.key});
  @override
  State<OutboundFixture> createState() => _OutboundFixtureState();
}

class _OutboundFixtureState extends State<OutboundFixture> {
  static const run = String.fromEnvironment('OUTBOUND_SHARE_RUN');
  String status = 'Ready';
  bool busy = false;
  Future<void> send(String kind) async {
    setState(() {
      busy = true;
      status = 'Running';
    });
    try {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(run)) {
        throw StateError('Missing run');
      }
      const origin = Rect.fromLTWH(10, 100, 100, 40);
      if (kind == 'binary' || kind == 'empty') {
        await AttachmentSharer().share(
          kind == 'binary' ? 'share-$run-附件?.BIN' : 'share-$run-empty.bin',
          Uint8List.fromList(kind == 'binary' ? [0, 1, 127, 128, 255] : []),
          origin,
        );
      } else {
        await NoteSharer().share(
          Note.fromJson({
            'Title': 'share-$run-$kind',
            'Content': kind == 'md'
                ? '# 原文 📝\n\n**不截断**'
                : '<p>原文 &amp; emoji 📝</p>',
            'IsMarkdown': kind == 'md',
            'UserId': 'private-account-not-for-sharing',
          }),
          origin,
        );
      }
      status = 'Returned $kind';
    } catch (error) {
      status = 'FAIL $error';
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Outbound share verification')),
    body: Column(
      children: [
        Text(status),
        for (final kind in ['md', 'html', 'binary', 'empty'])
          TextButton(
            onPressed: busy ? null : () => send(kind),
            child: Text('Share $kind'),
          ),
      ],
    ),
  );
}
