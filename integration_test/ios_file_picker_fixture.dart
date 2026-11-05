import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_bundle.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/services/note_exporter.dart';
import 'package:gemsnote/services/hugo_export.dart';
import 'package:gemsnote/services/rich_document.dart';

import 'dart:convert';

import 'package:gemsnote/services/note_importer.dart';

/// Test-only UI around the production services, without accounts or networking.
void main() => runApp(const MaterialApp(home: PickerFixture()));

class PickerFixture extends StatefulWidget {
  const PickerFixture({super.key});
  @override
  State<PickerFixture> createState() => _PickerFixtureState();
}

class _PickerFixtureState extends State<PickerFixture> {
  static const run = String.fromEnvironment('FILE_PICKER_RUN');
  static const strings = AppStrings(Locale('en'));
  final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
  String status = 'Ready';
  bool busy = false;

  Note note(String kind) => Note.fromJson({
    'Title': 'gemsnote-$run-$kind',
    'Content': kind == 'html'
        ? '<p>原文 &amp; emoji 📝</p>\n<table><tr><td>保留</td></tr></table>'
        : '# 原文 📝\n\n换行与 **格式**\n',
    'IsMarkdown': kind != 'html',
    'Tags': ['设备验证'],
    'IsStar': true,
  });

  Future<void> perform(String action, String kind) async {
    setState(() {
      busy = true;
      status = 'Running';
    });
    try {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(run)) {
        throw StateError('Missing run ID');
      }
      final expected = note(kind);
      if (action == 'export') {
        final exporter = NoteExporter(strings: strings);
        final saved = kind == 'gemsnote'
            ? await exporter.exportBundle(
                NoteBundle(expected, [
                  BundledResource(
                    file: AttachmentUpload(name: 'original.bin', bytes: bytes),
                    isImage: false,
                  ),
                ]),
              )
            : await exporter.export(expected);
        status = '${saved ? 'PASS' : 'CANCEL'} $action $kind';
      } else {
        final actual = await NoteImporter(strings: strings).pick();
        if (actual == null) {
          status = 'CANCEL $action $kind';
        } else {
          if (actual.title != expected.title ||
              actual.content !=
                  (kind == 'gemsnote'
                      ? expected.content
                      : kind == 'html'
                      ? rtfToHtml(
                          Uint8List.fromList(
                            utf8.encode(
                              htmlToRtf(
                                expected.content,
                                title: expected.title,
                              ),
                            ),
                          ),
                        )
                      : hugoMarkdown(expected, '')) ||
              actual.isMarkdown != expected.isMarkdown) {
            throw StateError('Source changed');
          }
          if (kind == 'gemsnote') {
            final bundle = actual.bundle;
            if (bundle == null ||
                bundle.resources.length != 1 ||
                bundle.resources.single.file.bytes.join(',') !=
                    bytes.join(',') ||
                bundle.note.tags.join(',') != expected.tags.join(',') ||
                !bundle.note.isStarred) {
              throw StateError('Bundle changed');
            }
          }
          status = 'PASS $action $kind';
        }
      }
    } catch (error) {
      status = 'FAIL $error';
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('File picker verification')),
    body: Column(
      children: [
        Text(status),
        for (final kind in ['md', 'html', 'gemsnote'])
          for (final action in ['export', 'import'])
            TextButton(
              onPressed: busy ? null : () => perform(action, kind),
              child: Text('$action $kind'),
            ),
      ],
    ),
  );
}
