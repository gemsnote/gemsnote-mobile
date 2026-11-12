import 'dart:convert';

import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';

class HugoMarkdown {
  const HugoMarkdown(
    this.title,
    this.content,
    this.tags,
    this.createdTime,
    this.updatedTime,
  );
  final String title, content;
  final List<String> tags;
  final String? createdTime, updatedTime;
}

HugoMarkdown parseHugoMarkdown(String content, String fallbackTitle) {
  content = content.replaceFirst(RegExp(r'^\ufeff'), '');
  Object? metadata;
  var end = 0;
  final opening = RegExp(r'^(---|\+\+\+)[ \t]*\r?\n').firstMatch(content);
  if (opening != null) {
    final closing = RegExp(
      opening[1] == '---'
          ? r'^---[ \t]*(?:\r?\n|$)'
          : r'^\+\+\+[ \t]*(?:\r?\n|$)',
      multiLine: true,
    ).firstMatch(content.substring(opening.end));
    if (closing == null) {
      return HugoMarkdown(fallbackTitle, content, const [], null, null);
    }
    final header = content.substring(opening.end, opening.end + closing.start);
    try {
      metadata = opening[1] == '---'
          ? loadYaml(header)
          : TomlDocument.parse(header).toMap();
    } on Object {
      throw const FormatException('Hugo 元数据格式无效');
    }
    end = opening.end + closing.end;
  } else if (content.startsWith('{')) {
    var depth = 0, quoted = false, escaped = false;
    for (var i = 0; i < content.length; i++) {
      final ch = content[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          quoted = false;
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}' && --depth == 0) {
        try {
          metadata = jsonDecode(content.substring(0, i + 1));
        } on FormatException {
          break;
        }
        end = i + 1;
        if (content.substring(end).startsWith('\r\n')) {
          end += 2;
        } else if (content.substring(end).startsWith('\n')) {
          end++;
        }
        break;
      }
    }
  }
  if (end == 0) {
    return HugoMarkdown(fallbackTitle, content, const [], null, null);
  }
  if (metadata is! Map) throw const FormatException('Hugo 元数据格式无效');
  final fields = {
    for (final entry in metadata.entries)
      entry.key.toString().toLowerCase(): entry.value,
  };
  String? date(Object? value) {
    if (value == null || value == '') return null;
    final text = value.toString();
    var normalized = text.replaceFirst(' ', 'T');
    if (RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(text)) {
      normalized += 'T00:00:00Z';
    } else if (RegExp(r'T\d\d:\d\d(?::\d\d(?:\.\d+)?)?$')
        .hasMatch(normalized)) {
      normalized += 'Z';
    }
    final parsed = DateTime.tryParse(normalized);
    if (!RegExp(r'^\d{4}-\d\d-\d\d').hasMatch(text) || parsed == null) {
      throw const FormatException('Hugo 日期无效');
    }
    return parsed.toUtc().toIso8601String();
  }

  final created = date(fields['date']),
      updated = date(fields['lastmod'] ?? fields['modified']);
  if (created == null && updated == null) {
    throw const FormatException('Hugo 元数据缺少创建或修改时间');
  }
  final title = fields['title'];
  if (title != null && title is! String) {
    throw const FormatException('Hugo 标题必须是文本');
  }
  final tags = fields['tags'] == null
      ? const []
      : fields['tags'] is String
      ? [fields['tags']]
      : fields['tags'];
  if (tags is! List || tags.any((tag) => tag is! String || tag.contains(','))) {
    throw const FormatException('Hugo 标签格式无效');
  }
  return HugoMarkdown(
    title as String? ?? '',
    content.substring(end).replaceFirst(RegExp(r'^\r?\n'), ''),
    tags
        .cast<String>()
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList(),
    created ?? updated,
    updated ?? created,
  );
}
