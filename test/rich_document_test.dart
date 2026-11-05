import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/rich_document.dart';
import 'package:gemsnote/services/note_importer.dart';
import 'package:gemsnote/ui/visual_html_policy.dart';

import 'note_import_test.dart' show PickedSource;

void main() {
  test('RTF round trip preserves Unicode, formatting, links and tables', () {
    final rtf = htmlToRtf(
      '<h1>标题</h1><p><b>中文😀</b><i>italic</i><u>under</u><a href="https://example.com">link</a></p><table><tr><td>A</td><td>B</td></tr></table><p>after</p>',
      title: 'Title {\\}',
    );
    expect(rtf, startsWith(r'{\rtf1'));
    final html = rtfToHtml(Uint8List.fromList(utf8.encode(rtf)));
    expect(html.replaceAll(RegExp('<[^>]+>'), ''), contains('中文😀'));
    expect(html, contains('<strong>'));
    expect(supportsVisualHtml(html), isTrue);
    expect(html, contains('<em>italic</em>'));
    expect(html, contains('href="https://example.com"'));
    expect(html, contains('<td>A</td><td>B</td>'));
    expect(html, contains('</table><p>after</p>'));
  });
  test(
    'RTF handles GBK, Unicode fallback, destinations and malformed input',
    () {
      final html = rtfToHtml(
        Uint8List.fromList(
          utf8.encode(
            r"{\rtf1\ansi\ansicpg936 \'d6\'d0\'ce\'c4\uc1\u20013?{\*\generator hidden;}\par {\object unsafe} text}",
          ),
        ),
      );
      expect(html, contains('中文'));
      expect(html, isNot(contains('hidden')));
      expect(html, isNot(contains('unsafe')));
      for (final source in [
        'bad',
        r'{\rtf1 missing',
        r'{\rtf1 \bin999 x}',
        r'{\rtf1 text} trailing',
      ]) {
        expect(
          () => rtfToHtml(Uint8List.fromList(utf8.encode(source))),
          throwsFormatException,
        );
      }
    },
  );
  const word =
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>中文😀</w:t></w:r><w:hyperlink r:id="r1"><w:r><w:t>link</w:t></w:r></w:hyperlink></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>';
  Uint8List docx(String xml) {
    final archive = Archive();
    for (final entry in {
      'word/document.xml': xml,
      'word/_rels/document.xml.rels': '<Relationships><Relationship Id="r1" Type="x/hyperlink" Target="javascript:alert(1)" TargetMode="External"/></Relationships>',
    }.entries) {
      final b = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, b.length, b));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  test(
    'DOCX produces rich HTML and rejects unsafe XML without fetching resources',
    () {
      final html = docxToHtml(docx(word));
      expect(html, contains('<strong>中文😀</strong>'));
      expect(supportsVisualHtml(html), isTrue);
      expect(html, contains('<td><p>cell</p></td>'));
      expect(html, isNot(contains('javascript')));
      expect(
        () => docxToHtml(
          docx('<!DOCTYPE x [<!ENTITY x SYSTEM "file:///etc/passwd">]>$word'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'RTF and DOCX picker results are rich-text notes with a conversion notice',
    () async {
      for (final entry in {
        'rtf': Uint8List.fromList(utf8.encode(htmlToRtf('<p><b>bold</b></p>'))),
        'docx': docx(word),
      }.entries) {
        final note = await NoteImporter(
          pick: () async => PickedSource('Example.${entry.key}', entry.value),
        ).pick();
        expect(note!.isMarkdown, isFalse);
        expect(note.title, 'Example');
        expect(note.content, contains('<strong>'));
        expect(note.warning, isNotEmpty);
      }
    },
  );
}
