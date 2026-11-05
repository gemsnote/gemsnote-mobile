import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_upload.dart';
import 'note.dart';

class BundledResource {
  BundledResource({
    required this.file,
    required this.isImage,
    this.sourceId = '',
    this.origin = '',
  }) {
    if (sourceId.isNotEmpty &&
        !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(sourceId)) {
      throw const FormatException('归档中的资源编号无效。');
    }
    if (origin.isNotEmpty) {
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.userInfo.isNotEmpty ||
          uri.origin != origin) {
        throw const FormatException('归档中的资源来源无效。');
      }
    }
    if (sourceId.isNotEmpty && origin.isEmpty) {
      throw const FormatException('归档中的资源来源无效。');
    }
  }
  final AttachmentUpload file;
  final bool isImage;
  final String sourceId, origin;
}

/// A bounded, lossless package. External URLs remain source text, never fetched.
class NoteBundle {
  NoteBundle(this.note, Iterable<BundledResource> resources)
    : resources = List.unmodifiable(resources) {
    if (utf8.encode(note.content).length > 8 * 1024 * 1024 ||
        note.title.length > 10000 ||
        this.resources.length > 64 ||
        this.resources.fold<int>(0, (n, r) => n + r.file.bytes.length) >
            32 * 1024 * 1024) {
      throw StateError('资源归档超过限制：原文 8 MiB，资源共 32 MiB、最多 64 项。');
    }
    final ids = <String>{};
    for (final r in this.resources) {
      if (r.sourceId.isNotEmpty && !ids.add('${r.origin}:${r.sourceId}')) {
        throw const FormatException('归档包含重复资源。');
      }
    }
  }
  final Note note;
  final List<BundledResource> resources;
  static const maxArchiveBytes = 64 * 1024 * 1024;

  Uint8List encode() {
    final result = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'gemsnote-bundle',
          'version': 1,
          'note': {
            'title': note.title,
            'content': note.content,
            'markdown': note.isMarkdown,
            'tags': note.tags,
            'starred': note.isStarred,
            'created': note.createdTime,
            'updated': note.updatedTime,
          },
          'resources': resources
              .map(
                (r) => {
                  'name': r.file.name,
                  'image': r.isImage,
                  'sourceId': r.sourceId,
                  'origin': r.origin,
                  'sha256': sha256.convert(r.file.bytes).toString(),
                  'bytes': base64Encode(r.file.bytes),
                },
              )
              .toList(),
        }),
      ),
    );
    if (result.length > maxArchiveBytes) {
      throw StateError('资源归档超过限制：原文 8 MiB，资源共 32 MiB、最多 64 项。');
    }
    return result;
  }

  static NoteBundle decode(Uint8List bytes) {
    if (bytes.length > maxArchiveBytes) {
      throw StateError('资源归档超过限制：原文 8 MiB，资源共 32 MiB、最多 64 项。');
    }
    try {
      final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (value['format'] != 'gemsnote-bundle' || value['version'] != 1) {
        throw const FormatException('笔记归档格式或版本无效。');
      }
      final n = value['note'] as Map<String, dynamic>;
      final list = value['resources'] as List;
      if (list.length > 64) {
        throw StateError('资源归档超过限制：原文 8 MiB，资源共 32 MiB、最多 64 项。');
      }
      var total = 0;
      final resources = <BundledResource>[];
      for (final entry in list) {
        final r = entry as Map<String, dynamic>;
        final content = base64Decode(r['bytes'] as String);
        total += content.length;
        if (total > 32 * 1024 * 1024) {
          throw StateError('资源归档超过限制：原文 8 MiB，资源共 32 MiB、最多 64 项。');
        }
        if (sha256.convert(content).toString() != r['sha256']) {
          throw const FormatException('资源校验失败，归档可能已损坏。');
        }
        resources.add(
          BundledResource(
            file: AttachmentUpload(name: r['name'] as String, bytes: content),
            isImage: r['image'] as bool,
            sourceId: r['sourceId'] as String,
            origin: r['origin'] as String,
          ),
        );
      }
      return NoteBundle(
        Note(
          noteId: '',
          notebookId: '',
          userId: '',
          title: n['title'] as String,
          content: n['content'] as String,
          tags: (n['tags'] as List).cast<String>(),
          usn: 0,
          isMarkdown: n['markdown'] as bool,
          isStarred: n['starred'] as bool,
          isTrash: false,
          isDeleted: false,
          createdTime: n['created'] as String,
          updatedTime: n['updated'] as String,
        ),
        resources,
      );
    } on TypeError {
      throw const FormatException('笔记归档格式或版本无效。');
    }
  }
}

/// Replace only URLs for the captured origin and resource ID. No HTML parsing
/// or serialization: formatting, attributes and all unrelated source stay intact.
String rebindResource(String body, BundledResource resource, String remoteId) {
  if (resource.sourceId.isEmpty) return body;
  final urls = RegExp(
    r'''https?://[^\s"'<>()[\]]+|(?<![\w/:])/(?:api2/file/getImage|api/file/getImage|file/outputImage|api2/file/getAttach|api/file/getAttach|attach/download)\?[^\s"'<>()[\]]+''',
  );
  return body.replaceAllMapped(urls, (match) {
    final raw = match[0]!;
    final uri = Uri.tryParse(raw.replaceAll('&amp;', '&'));
    if (uri == null || !matchesBundledResource(uri, resource)) return raw;
    return '/api2/file/${resource.isImage ? 'getImage' : 'getAttach'}?fileId=$remoteId';
  });
}

bool matchesBundledResource(Uri uri, BundledResource resource) {
  if (resource.sourceId.isEmpty || resource.origin.isEmpty) return false;
  final resolved = Uri.parse(resource.origin).resolveUri(uri);
  return {'http', 'https'}.contains(resolved.scheme) &&
      resolved.host.isNotEmpty &&
      resolved.origin == resource.origin &&
      resolved.userInfo.isEmpty &&
      resolved.queryParametersAll['fileId']?.length == 1 &&
      resolved.queryParameters['fileId'] == resource.sourceId &&
      (resource.isImage
              ? const {
                  '/api2/file/getImage',
                  '/api/file/getImage',
                  '/file/outputImage',
                }
              : const {
                  '/api2/file/getAttach',
                  '/api/file/getAttach',
                  '/attach/download',
                })
          .contains(resolved.path);
}
