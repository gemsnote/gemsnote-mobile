import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

import 'note_image_reference.dart';

/// Images actually represented by a body, excluding code and arbitrary links.
Set<String> bodyImageIds(
  String body, {
  required bool isMarkdown,
  required Uri server,
}) {
  final ids = <String>{};
  void add(String? source) {
    if (source == null || ids.length >= 100) return;
    final uri = Uri.tryParse(source);
    if (uri == null) return;
    final id = cachedImageFileId(uri, server);
    if (id != null) ids.add(id);
  }

  if (isMarkdown) {
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    void visit(List<md.Node> nodes, int depth) {
      if (depth >= 64 || ids.length >= 100) return;
      for (final node in nodes) {
        if (node is! md.Element) continue;
        if (node.tag == 'img') add(node.attributes['src']);
        if (node.tag != 'code' && node.tag != 'pre') {
          visit(node.children ?? [], depth + 1);
        }
      }
    }

    visit(document.parseLines(body.split('\n')), 0);
  } else {
    for (final image in html.parseFragment(body).querySelectorAll('img')) {
      add(image.attributes['src']);
      if (ids.length >= 100) break;
    }
  }
  return ids;
}

/// A new note needs a server ID before its staged images can be uploaded.
/// Create it with the staged img nodes omitted; the local body remains intact
/// and is updated after the originals receive real FileIds.
String bodyWithoutPendingVisualImages(
  String body,
  Uri server,
  Set<String> pendingIds,
) {
  if (pendingIds.isEmpty) return body;
  final fragment = html.parseFragment(body);
  final removed = <String>{};
  for (final image in fragment.querySelectorAll('img')) {
    final source = image.attributes['src'];
    final uri = source == null ? null : Uri.tryParse(source);
    final id = uri == null ? null : cachedImageFileId(uri, server);
    if (id != null && pendingIds.contains(id)) {
      removed.add(id);
      image.remove();
    }
  }
  if (!removed.containsAll(pendingIds)) {
    throw StateError('待上传图片引用无法从新笔记正文安全移除');
  }
  final safe = fragment.outerHtml;
  if (pendingIds.any(safe.contains)) {
    throw StateError('新笔记正文仍含待上传图片引用');
  }
  return safe;
}

/// Attachment URLs in source text must have matching originals before a note
/// can be copied. A conservative scan also catches links in unsupported markup.
Set<String> bodyAttachmentIds(String body, Uri server) {
  final ids = <String>{};
  final urls = RegExp(
    r'''https?://[^\s"'<>()[\]]+|(?<![\w/:])/(?:api2/file/getAttach|api/file/getAttach|attach/download)\?[^\s"'<>()[\]]+''',
  );
  for (final match in urls.allMatches(body)) {
    final uri = Uri.tryParse(match[0]!.replaceAll('&amp;', '&'));
    if (uri == null) continue;
    final resolved = server.resolveUri(uri);
    if (resolved.origin != server.origin ||
        resolved.userInfo.isNotEmpty ||
        !const {
          '/api2/file/getAttach',
          '/api/file/getAttach',
          '/attach/download',
        }.contains(resolved.path)) {
      continue;
    }
    final values = resolved.queryParametersAll['fileId'];
    if (values?.length == 1 &&
        RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(values!.single)) {
      ids.add(values.single);
    }
  }
  return ids;
}
