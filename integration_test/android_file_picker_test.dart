import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_bundle.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/services/note_exporter.dart';
import 'package:gemsnote/services/hugo_export.dart';
import 'package:gemsnote/services/rich_document.dart';

import 'dart:convert';

import 'package:gemsnote/services/note_importer.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('FILE_PICKER_RUN');
  testWidgets('Android system picker exports and imports exact source', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(run), isTrue);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('File picker verification'))),
    );
    const strings = AppStrings(Locale('en'));
    final exporter = NoteExporter(strings: strings);
    final importer = NoteImporter(strings: strings);
    final original = Uint8List.fromList([0, 1, 127, 128, 255]);
    for (final kind in ['md', 'html', 'gemsnote']) {
      final note = Note.fromJson({
        'Title': 'gemsnote-$run-$kind',
        'Content': kind == 'html'
            ? '<p>原文 &amp; emoji 📝</p>\n<table><tr><td>保留</td></tr></table>'
            : '# 原文 📝\n\n换行与 **格式**\n',
        'IsMarkdown': kind != 'html',
        'Tags': ['设备验证'],
        'IsStar': true,
      });
      final bundle = NoteBundle(note, [
        BundledResource(
          file: AttachmentUpload(name: 'original.bin', bytes: original),
          isImage: false,
        ),
      ]);
      debugPrint('FILE_PICKER_STAGE:save:$kind');
      expect(
        kind == 'gemsnote'
            ? await exporter.exportBundle(bundle)
            : await exporter.export(note),
        isTrue,
      );
      debugPrint('FILE_PICKER_STAGE:import:$kind');
      final imported = await importer.pick();
      expect(imported, isNotNull);
      expect(imported!.title, note.title);
      expect(
        imported.content,
        kind == 'gemsnote'
            ? note.content
            : kind == 'html'
            ? rtfToHtml(
                Uint8List.fromList(
                  utf8.encode(htmlToRtf(note.content, title: note.title)),
                ),
              )
            : hugoMarkdown(note, ''),
      );
      expect(imported.isMarkdown, note.isMarkdown);
      if (kind == 'gemsnote') {
        expect(imported.bundle!.resources.single.file.bytes, original);
        expect(imported.bundle!.note.tags, note.tags);
        expect(imported.bundle!.note.isStarred, isTrue);
      } else {
        expect(imported.bundle, isNull);
      }
    }
    debugPrint('FILE_PICKER_STAGE:invalid');
    await expectLater(importer.pick(), throwsFormatException);
    debugPrint('FILE_PICKER_STAGE:cancel:export');
    expect(
      await exporter.export(
        Note.fromJson({
          'Title': 'gemsnote-$run-cancel',
          'Content': 'must not be saved',
          'IsMarkdown': true,
        }),
      ),
      isFalse,
    );
    debugPrint('FILE_PICKER_STAGE:cancel:import');
    expect(await importer.pick(), isNull);
    debugPrint('FILE_PICKER_STAGE:complete');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
