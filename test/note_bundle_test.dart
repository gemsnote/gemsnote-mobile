import 'dart:convert';
import 'dart:typed_data';

import 'note_import_test.dart' show PickedSource;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_bundle.dart';
import 'package:gemsnote/services/note_exporter.dart';
import 'package:gemsnote/services/note_importer.dart';

void main() {
  const id = '507f1f77bcf86cd799439011', next = '507f1f77bcf86cd799439022';
  final bytes = Uint8List.fromList([0, 255, 1, 2]);
  final resource = BundledResource(
    file: AttachmentUpload(name: '原件.bin', bytes: bytes),
    isImage: true,
    sourceId: id,
    origin: 'https://old.test',
  );
  final note = Note.fromJson({
    'Title': '原文',
    'Content':
        '<table style="custom:x"><tr><td><img src="https://old.test/file/outputImage?fileId=$id&amp;noteId=x"></td></tr></table>',
    'Tags': ['tag'],
    'IsStar': true,
  });
  test('lossless archive retains complex HTML, metadata and binary originals without account credentials', () {
    final bundle = NoteBundle(note, [resource]);
    final decoded = NoteBundle.decode(bundle.encode());
    expect(decoded.note.content, note.content);
    expect(decoded.note.tags, note.tags);
    expect(decoded.note.isStarred, true);
    expect(decoded.resources.single.file.bytes, bytes);
    expect(decoded.resources.single.origin, 'https://old.test');
    expect(decoded.note.userId, isEmpty);
    expect(decoded.note.usn, 0);
  });
  test(
    'reference rebinding preserves all unrelated markup and external origins',
    () {
      expect(
        rebindResource(note.content, resource, next),
        note.content.replaceFirst(
          'https://old.test/file/outputImage?fileId=$id&amp;noteId=x',
          '/api2/file/getImage?fileId=$next',
        ),
      );
      final external =
          '<img src="https://other.test/file/outputImage?fileId=$id">';
      expect(rebindResource(external, resource, next), external);
      final md = '![](/api2/file/getImage?fileId=$id)';
      expect(
        rebindResource(md, resource, next),
        '![](/api2/file/getImage?fileId=$next)',
      );
      expect(
        matchesBundledResource(
          Uri.parse('file:///api2/file/getImage?fileId=$id'),
          resource,
        ),
        false,
      );
    },
  );
  test('attachment links are rebound without appending images or changing visible text', () {
    final file = BundledResource(
      file: resource.file,
      isImage: false,
      sourceId: id,
      origin: resource.origin,
    );
    expect(
      rebindResource('[download](/api2/file/getAttach?fileId=$id)', file, next),
      '[download](/api2/file/getAttach?fileId=$next)',
    );
  });
  for (final mode in [
    'checksum',
    'type',
    'version',
    'path',
    'origin',
    'duplicate',
  ]) {
    test('rejects corrupt or invalid archive: $mode', () {
      final json = jsonDecode(
        utf8.decode(NoteBundle(note, [resource]).encode()),
      ) as Map<String, dynamic>;
      final item = (json['resources'] as List).single as Map;
      switch (mode) {
        case 'checksum':
          item['sha256'] = 'bad';
        case 'type':
          item['image'] = 'yes';
        case 'version':
          json['version'] = 2;
        case 'path':
          item['name'] = '../secret';
        case 'origin':
          item['origin'] = 'https://user:password@old.test';
        case 'duplicate':
          (json['resources'] as List).add(item);
      }
      expect(
        () => NoteBundle.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
    });
  }
  test('bounds resource count and source size', () {
    expect(() => NoteBundle(note, List.filled(65, resource)), throwsStateError);
    expect(
      () => NoteBundle(note.copyWith(content: 'x' * (8 * 1024 * 1024 + 1)), []),
      throwsStateError,
    );
  });
  test('system save and import picker round-trip a bundle', () async {
    Uint8List? saved;
    final exporter = NoteExporter(
      save: ({required fileName, required bytes, required mimeType}) async {
        expect(fileName, '原文.gemsnote');
        expect(mimeType, 'application/json');
        saved = bytes;
        return Uri.parse('content://saved');
      },
    );
    expect(await exporter.exportBundle(NoteBundle(note, [resource])), true);
    final importer = NoteImporter(
      pick: () async => PickedSource('原文.gemsnote', saved!),
    );
    final imported = (await importer.pick())!;
    expect(imported.content, note.content);
    expect(imported.bundle!.resources.single.file.bytes, bytes);
  });
}
