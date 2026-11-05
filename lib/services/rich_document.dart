import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

const richDocumentWarning = '复杂排版、内嵌图片和对象可能简化；图片以占位文字保留，请核对导入结果。';
String _escape(String value) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
bool _safeLink(String value) =>
    RegExp(r'^(https?://|mailto:)', caseSensitive: false).hasMatch(value) &&
    !RegExp(r'[\x00-\x20"<>]').hasMatch(value);
String _rtfText(String value) => value.codeUnits
    .map(
      (n) => switch (n) {
        92 || 123 || 125 => '\\${String.fromCharCode(n)}',
        10 => r'\line ',
        9 => r'\tab ',
        13 => '',
        >= 32 && < 127 => String.fromCharCode(n),
        _ => '\\u${n > 32767 ? n - 65536 : n}?',
      },
    )
    .join();
Map<String, String> _css(dom.Element node) => Map.fromEntries(
  (node.attributes['style'] ?? '')
      .split(';')
      .map((s) => s.split(':'))
      .where((s) => s.length == 2)
      .map(
        (s) => MapEntry(s[0].trim().toLowerCase(), s[1].trim().toLowerCase()),
      ),
);
String? _rgb(String value) {
  if (RegExp(r'^#[0-9a-f]{6}$', caseSensitive: false).hasMatch(value)) {
    return value.toLowerCase();
  }
  if (RegExp(r'^#[0-9a-f]{3}$', caseSensitive: false).hasMatch(value)) {
    return '#${value.substring(1).split('').map((c) => '$c$c').join()}';
  }
  final match = RegExp(r'^rgb\(\s*(\d+),\s*(\d+),\s*(\d+)\s*\)$')
      .firstMatch(value);
  if (match != null) {
    return '#${[1, 2, 3].map((i) => int.parse(match[i]!).clamp(0, 255).toRadixString(16).padLeft(2, '0')).join()}';
  }
  return {
    'red': '#ff0000',
    'blue': '#0000ff',
    'green': '#008000',
    'black': '#000000',
    'white': '#ffffff',
  }[value];
}

String htmlToRtf(String source, {String title = ''}) {
  final document = html.parseFragment(source), colors = <String>[];
  String color(String value) {
    final hex = _rgb(value);
    if (hex == null) return '';
    if (!colors.contains(hex)) colors.add(hex);
    return '\\cf${colors.indexOf(hex) + 1} ';
  }

  String render(dom.Node node, [int depth = 0]) {
    if (depth > 100) throw const FormatException('文档内容过大或结构过于复杂');
    if (node is dom.Text) return _rtfText(node.data);
    if (node is! dom.Element) {
      return node.nodes.map((n) => render(n, depth + 1)).join();
    }
    final name = node.localName!, style = _css(node);
    if (['script', 'style', 'iframe', 'object', 'head'].contains(name)) {
      return '';
    }
    String body() => node.nodes.map((n) => render(n, depth + 1)).join();
    if (name == 'br') return r'\line ';
    if (name == 'hr') return r'\par ____________________\par ';
    if (name == 'img') {
      return _rtfText(
        '[${node.attributes['alt'] ?? 'Image'}] ${node.attributes['src'] ?? ''}',
      );
    }
    if (name == 'table') return '${body()}\\par ';
    if (name == 'tr') {
      final cells = node.children
          .where((n) => ['td', 'th'].contains(n.localName))
          .toList();
      return r'\trowd ' +
          List.generate(
            cells.length,
            (i) =>
                '\\cellx${(i + 1) * (9000 / (cells.isEmpty ? 1 : cells.length)).floor()} ',
          ).join() +
          cells.map((n) => '\\intbl ${render(n, depth + 1)}\\cell ').join() +
          r'\row ';
    }
    var controls = '';
    if (['b', 'strong', 'th'].contains(name) ||
        ['bold', '700', '800', '900'].contains(style['font-weight'])) {
      controls += r'\b ';
    }
    if (['i', 'em'].contains(name) || style['font-style'] == 'italic') {
      controls += r'\i ';
    }
    if (name == 'u' || (style['text-decoration'] ?? '').contains('underline')) {
      controls += r'\ul ';
    }
    if (['s', 'strike', 'del'].contains(name) ||
        (style['text-decoration'] ?? '').contains('line-through')) {
      controls += r'\strike ';
    }
    if (name == 'sup') controls += r'\super ';
    if (name == 'sub') controls += r'\sub ';
    final heading = RegExp(r'^h([1-6])$').firstMatch(name);
    if (heading != null) {
      controls += '\\b\\fs${48 - (int.parse(heading[1]!) - 1) * 4} ';
    }
    final size = RegExp(r'^(\d+(?:\.\d+)?)(pt|px)$')
        .firstMatch(style['font-size'] ?? '');
    if (size != null) {
      controls +=
          '\\fs${(double.parse(size[1]!) * (size[2] == 'px' ? 1.5 : 2)).round().clamp(12, 144)} ';
    }
    controls += color(style['color'] ?? node.attributes['color'] ?? '');
    controls +=
        {
          'left': r'\ql ',
          'center': r'\qc ',
          'right': r'\qr ',
          'justify': r'\qj ',
        }[style['text-align'] ?? node.attributes['align']] ??
        '';
    var text = body();
    final href = node.attributes['href'] ?? '';
    if (name == 'a' && _safeLink(href)) {
      text =
          '{\\field{\\*\\fldinst HYPERLINK "${_rtfText(href)}"}{\\fldrslt $text}}';
    }
    if (name == 'li') {
      final parent = node.parent;
      final index =
          parent?.children
              .where((n) => n.localName == 'li')
              .toList()
              .indexOf(node) ??
          0;
      text =
          _rtfText(parent?.localName == 'ol' ? '${index + 1}. ' : '• ') + text;
    }
    if (['p', 'div', 'li', 'blockquote', 'pre'].contains(name) ||
        heading != null) {
      text += r'\par ';
    }
    return '{$controls$text}';
  }

  final body = render(document),
      colorTable = colors
          .map(
            (c) =>
                '\\red${int.parse(c.substring(1, 3), radix: 16)}\\green${int.parse(c.substring(3, 5), radix: 16)}\\blue${int.parse(c.substring(5, 7), radix: 16)};',
          )
          .join();
  return '{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0\\fnil Arial;}}{\\colortbl;$colorTable}{\\info{\\title ${_rtfText(title)}}}\\f0\\fs24 $body}';
}

String rtfToHtml(Uint8List bytes) {
  final source = latin1.decode(bytes);
  if (!RegExp(r'^\{\\rtf1(?:\D|$)').hasMatch(source) ||
      source.length > 32 * 1024 * 1024) {
    throw const FormatException('文档损坏或格式不受支持');
  }
  final colorTable =
      RegExp(r'\{\\colortbl([^{}]*)\}').firstMatch(source)?[1] ?? '';
  final colors = colorTable.split(';').map((c) {
    int get(String key) =>
        int.parse(RegExp('\\\\$key(\\d+)').firstMatch(c)?[1] ?? '0')
            .clamp(0, 255);
    return 'rgb(${get('red')},${get('green')},${get('blue')})';
  }).toList();
  Map<String, dynamic> state = {
    'skip': false,
    'uc': 1,
    'b': false,
    'i': false,
    'ul': false,
    'strike': false,
    'fs': 24,
    'cf': 0,
    'align': '',
    'link': '',
    'instruction': false,
  };
  final stack = <Map<String, dynamic>>[], pending = <int>[];
  var fallback = 0,
      codepage = 1252,
      line = '',
      result = '',
      surrogate = '',
      table = false,
      pos = 0,
      closed = false;
  List<String>? row;
  void flushParagraph() {
    if (row != null) {
      if (line.isNotEmpty) line += '<br>';
      return;
    }
    if (table) {
      result += '</table>';
      table = false;
    }
    if (line.isNotEmpty) {
      result +=
          '<p${state['align'] != '' ? ' style="text-align:${state['align']}"' : ''}>$line</p>';
      line = '';
    }
  }

  void text(String value) {
    value = surrogate + value;
    surrogate = '';
    if (value.isNotEmpty &&
        value.codeUnitAt(value.length - 1) >= 0xd800 &&
        value.codeUnitAt(value.length - 1) <= 0xdbff) {
      surrogate = value.substring(value.length - 1);
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) return;
    if (state['instruction'] == true) {
      if (state['field'] != null) state['field']['instruction'] += value;
      return;
    }
    if (state['skip'] == true) return;
    var out = _escape(value);
    for (final pair in [
      ('b', 'strong'),
      ('i', 'em'),
      ('ul', 'u'),
      ('strike', 's'),
    ]) {
      if (state[pair.$1] == true) out = '<${pair.$2}>$out</${pair.$2}>';
    }
    final size = state['fs'] as int, cf = state['cf'] as int;
    final style =
        (size != 24 ? 'font-size:${size / 2}pt;' : '') +
        (cf > 0 && cf < colors.length ? 'color:${colors[cf]};' : '');
    if (style.isNotEmpty) out = '<span style="$style">$out</span>';
    if (state['link'] != '') {
      out = '<a href="${_escape(state['link'])}">$out</a>';
    }
    line += out;
    if (line.length + result.length > 32 * 1024 * 1024) {
      throw const FormatException('文档内容过大或结构过于复杂');
    }
  }

  void flush() {
    if (pending.isEmpty) return;
    if (pending.every((n) => n < 128)) {
      text(ascii.decode(pending));
      pending.clear();
      return;
    }
    final Encoding encoding = switch (codepage) {
      1252 => const Windows1252Codec(),
      936 => const GbkCodec(),
      950 => const Big5Codec(),
      65001 => utf8,
      1250 => const Windows1250Codec(),
      1251 => const Windows1251Codec(),
      1253 => const Windows1253Codec(),
      1254 => const Windows1254Codec(),
      1255 => const Windows1255Codec(),
      1256 => const Windows1256Codec(),
      _ => throw const FormatException(
        '不支持此 RTF 编码，请另存为 Unicode RTF 或 DOCX 后重试',
      ),
    };
    text(encoding.decode(pending));
    pending.clear();
  }

  void byte(int n) {
    if (fallback > 0) {
      fallback--;
      return;
    }
    if (state['skip'] == true && state['instruction'] != true) return;
    pending.add(n);
  }

  const skipped = {
    'fonttbl',
    'colortbl',
    'stylesheet',
    'info',
    'header',
    'headerl',
    'headerr',
    'footer',
    'footerl',
    'footerr',
    'listtable',
    'listoverridetable',
    'generator',
    'filetbl',
    'datastore',
    'xmlnstbl',
    'themedata',
    'colorschememapping',
  };
  while (pos < source.length) {
    final ch = source[pos++];
    if (closed) {
      if (ch.trim().isNotEmpty) {
        throw const FormatException('文档损坏或格式不受支持');
      }
      continue;
    }
    if (ch == '{' || ch == '}') {
      flush();
      fallback = 0;
      if (ch == '{') {
        if (stack.length >= 128) {
          throw const FormatException('文档内容过大或结构过于复杂');
        }
        stack.add(Map.of(state));
      } else {
        if (stack.isEmpty) throw const FormatException('文档损坏或格式不受支持');
        if (state['instruction'] == true && state['field'] != null) {
          final match = RegExp(
            r'HYPERLINK\s+"([^"\r\n]+)"',
            caseSensitive: false,
          ).firstMatch(state['field']['instruction']);
          if (match != null && _safeLink(match[1]!)) {
            state['field']['instruction'] = match[1]!;
          }
        }
        if (state['align'] != stack.last['align'] &&
            line.isNotEmpty &&
            row == null) {
          flushParagraph();
        }
        state = stack.removeLast();
        if (stack.isEmpty) closed = true;
      }
      continue;
    }
    if (ch == '\r' || ch == '\n') continue;
    if (ch != '\\') {
      byte(ch.codeUnitAt(0));
      continue;
    }
    if (pos >= source.length) {
      throw const FormatException('文档损坏或格式不受支持');
    }
    final next = source[pos++];
    if (next == "'") {
      if (pos + 2 > source.length) {
        throw const FormatException('文档损坏或格式不受支持');
      }
      final hex = source.substring(pos, pos + 2);
      if (!RegExp(r'^[a-f\d]{2}$', caseSensitive: false).hasMatch(hex)) {
        throw const FormatException('文档损坏或格式不受支持');
      }
      byte(int.parse(hex, radix: 16));
      pos += 2;
      continue;
    }
    if (['\\', '{', '}'].contains(next)) {
      byte(next.codeUnitAt(0));
      continue;
    }
    flush();
    if (next == '*') {
      state['skip'] = true;
      continue;
    }
    if (next == '~') {
      text('\u00a0');
      continue;
    }
    if (next == '-') {
      text('\u00ad');
      continue;
    }
    if (next == '_') {
      text('\u2011');
      continue;
    }
    if (!RegExp('[a-z]', caseSensitive: false).hasMatch(next)) continue;
    final start = pos - 1;
    while (pos < source.length &&
        RegExp('[a-z]', caseSensitive: false).hasMatch(source[pos])) {
      pos++;
    }
    final word = source.substring(start, pos),
        number = RegExp(r'^-?\d+').firstMatch(source.substring(pos)),
        n = number == null ? 1 : int.tryParse(number[0]!) ?? 0;
    if (number != null) pos += number[0]!.length;
    if (pos < source.length && source[pos] == ' ') pos++;
    if (word == 'bin') {
      if (number == null || n < 0 || pos + n > source.length) {
        throw const FormatException('文档损坏或格式不受支持');
      }
      pos += n;
      continue;
    }
    if (skipped.contains(word)) {
      state['skip'] = true;
      continue;
    }
    if (word == 'pict' || word == 'object') {
      if (state['skip'] != true) text('[Image / object]');
      state['skip'] = true;
      continue;
    }
    if (word == 'field') {
      state['field'] = {'instruction': ''};
      continue;
    }
    if (word == 'fldinst') {
      state['instruction'] = true;
      state['skip'] = true;
      continue;
    }
    if (word == 'fldrslt') {
      state['skip'] = false;
      state['instruction'] = false;
      final url = state['field']?['instruction'] ?? '';
      state['link'] = _safeLink(url) ? url : '';
      continue;
    }
    if (word == 'uc') {
      state['uc'] = n.clamp(0, 16);
      continue;
    }
    if (word == 'u') {
      if (n < -32768 || n > 65535) {
        throw const FormatException('文档损坏或格式不受支持');
      }
      text(String.fromCharCode(n & 65535));
      fallback = state['uc'];
      continue;
    }
    if (word == 'ansicpg') {
      codepage = n;
      continue;
    }
    if (state['skip'] == true) continue;
    if (['b', 'i', 'ul', 'strike'].contains(word)) {
      state[word] = n != 0;
    } else if (word == 'ulnone') {
      state['ul'] = false;
    } else if (word == 'fs') {
      state['fs'] = n.clamp(12, 144);
    } else if (word == 'cf') {
      state['cf'] = n;
    } else if (word == 'plain') {
      for (final key in ['b', 'i', 'ul', 'strike']) {
        state[key] = false;
      }
      state['fs'] = 24;
      state['cf'] = 0;
    } else if (['ql', 'qc', 'qr', 'qj'].contains(word)) {
      state['align'] = {
        'ql': 'left',
        'qc': 'center',
        'qr': 'right',
        'qj': 'justify',
      }[word];
    } else if (word == 'pard') {
      state['align'] = '';
    } else if (word == 'par') {
      flushParagraph();
    } else if (word == 'line') {
      line += '<br>';
    } else if (word == 'tab') {
      text('\u00a0\u00a0\u00a0\u00a0');
    } else if (word == 'trowd') {
      if (line.isNotEmpty) flushParagraph();
      row = [];
      if (!table) {
        result += '<table>';
        table = true;
      }
    } else if (word == 'cell' && row != null) {
      row.add(line);
      line = '';
    } else if (word == 'row' && row != null) {
      if (line.isNotEmpty) row.add(line);
      result += '<tr>${row.map((c) => '<td>$c</td>').join()}</tr>';
      line = '';
      row = null;
    } else {
      final special = {
        'emdash': '—',
        'endash': '–',
        'bullet': '•',
        'lquote': '‘',
        'rquote': '’',
        'ldblquote': '“',
        'rdblquote': '”',
      }[word];
      if (special != null) text(special);
    }
    if (table && row == null && word == 'pard') {
      result += '</table>';
      table = false;
    }
  }
  flush();
  if (stack.isNotEmpty || !closed) {
    throw const FormatException('文档损坏或格式不受支持');
  }
  if (table) {
    if (row != null) {
      row.add(line);
      result += '<tr>${row.map((c) => '<td>$c</td>').join()}</tr>';
      line = '';
    }
    result += '</table>';
    table = false;
  }
  flushParagraph();
  return result.isEmpty
      ? '<p></p>'
      : result.replaceAll('</ol><ol>', '').replaceAll('</ul><ul>', '');
}

String _attr(XmlElement? n, String name) =>
    n?.attributes.where((a) => a.name.local == name).firstOrNull?.value ?? '';
XmlElement? _child(XmlElement? n, String name) =>
    n?.childElements.where((c) => c.name.local == name).firstOrNull;
String docxToHtml(Uint8List bytes) {
  if (bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('文档内容过大或结构过于复杂');
  }
  // Inspect central and local headers before any decompression (including symlinks).
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.isEmpty || directory.fileHeaders.length > 5000) {
    throw const FormatException('文档损坏或格式不受支持');
  }
  final names = <String>{}, files = <String, Uint8List>{};
  var total = 0;
  const selected = {
    'word/document.xml',
    'word/styles.xml',
    'word/numbering.xml',
    'word/_rels/document.xml.rels',
  };
  for (final h in directory.fileHeaders) {
    if ((h.generalPurposeBitFlag & 1) != 0 ||
        ![0, 8].contains(h.compressionMethod) ||
        !names.add(h.filename) ||
        h.filename.startsWith('/') ||
        h.filename.contains('\\') ||
        h.filename.split('/').contains('..') ||
        (h.externalFileAttributes >> 16 & 0xf000) == 0xa000) {
      throw const FormatException('文档损坏或格式不受支持');
    }
    if (!selected.contains(h.filename)) continue;
    if (h.uncompressedSize > 4 * 1024 * 1024 ||
        (total += h.uncompressedSize) > 16 * 1024 * 1024 ||
        h.file == null ||
        h.file!.filename != h.filename ||
        h.file!.uncompressedSize != h.uncompressedSize) {
      throw const FormatException('文档内容过大或结构过于复杂');
    }
    final data = h.file!.getStream().toUint8List();
    if (data.length != h.uncompressedSize || getCrc32(data) != h.crc32) {
      throw const FormatException('文档损坏或格式不受支持');
    }
    files[h.filename] = data;
  }
  XmlElement? xml(String name) {
    final data = files[name];
    if (data == null) return null;
    final source = utf8.decode(data);
    if (RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(source)) {
      throw const FormatException('文档损坏或格式不受支持');
    }
    return XmlDocument.parse(source).rootElement;
  }

  final root = xml('word/document.xml');
  if (root == null || root.name.local != 'document') {
    throw const FormatException('文档损坏或格式不受支持');
  }
  final rels = <String, String>{};
  for (final r
      in xml('word/_rels/document.xml.rels')?.childElements ?? <XmlElement>[]) {
    final url = _attr(r, 'Target');
    if (_attr(r, 'Type').endsWith('/hyperlink') && _safeLink(url)) {
      rels[_attr(r, 'Id')] = url;
    }
  }
  final styles = {
    for (final s in xml('word/styles.xml')?.childElements ?? <XmlElement>[])
      _attr(s, 'styleId'): s,
  };
  final nums = xml('word/numbering.xml'),
      abstract = <String, String>{},
      numbering = <String, String>{};
  for (final a
      in nums?.childElements.where((n) => n.name.local == 'abstractNum') ??
          <XmlElement>[]) {
    abstract[_attr(a, 'abstractNumId')] = _attr(
      _child(_child(a, 'lvl'), 'numFmt'),
      'val',
    );
  }
  for (final n
      in nums?.childElements.where((n) => n.name.local == 'num') ??
          <XmlElement>[]) {
    numbering[_attr(n, 'numId')] =
        abstract[_attr(_child(n, 'abstractNumId'), 'val')] ?? 'bullet';
  }
  bool enabled(XmlElement? p, String name) =>
      _child(p, name) != null &&
      !['0', 'false', 'off', 'none'].contains(_attr(_child(p, name), 'val'));
  String run(XmlElement node) {
    final p = _child(node, 'rPr');
    var body = '';
    for (final c in node.childElements) {
      switch (c.name.local) {
        case 't':
          body += _escape(c.innerText);
        case 'tab':
          body += '&nbsp;&nbsp;&nbsp;&nbsp;';
        case 'br':
        case 'cr':
          body += '<br>';
        case 'drawing':
        case 'pict':
        case 'object':
          body += '[Image / object]';
      }
    }
    for (final pair in [
      ('b', 'strong'),
      ('i', 'em'),
      ('u', 'u'),
      ('strike', 's'),
    ]) {
      if (enabled(p, pair.$1)) body = '<${pair.$2}>$body</${pair.$2}>';
    }
    final color = _attr(_child(p, 'color'), 'val'),
        size = int.tryParse(_attr(_child(p, 'sz'), 'val')) ?? 0;
    final style =
        (RegExp(r'^[a-f\d]{6}$', caseSensitive: false).hasMatch(color)
            ? 'color:#$color;'
            : '') +
        (size >= 12 && size <= 144 ? 'font-size:${size / 2}pt;' : '');
    return style.isEmpty ? body : '<span style="$style">$body</span>';
  }

  String render(XmlElement node, [int depth = 0]) {
    if (depth > 100) throw const FormatException('文档内容过大或结构过于复杂');
    final name = node.name.local;
    String all() => node.childElements.map((n) => render(n, depth + 1)).join();
    if (name == 'r') return run(node);
    if (name == 'hyperlink') {
      final body = all(), url = rels[_attr(node, 'id')];
      return url == null ? body : '<a href="${_escape(url)}">$body</a>';
    }
    if (name == 'p') {
      final p = _child(node, 'pPr'),
          id = _attr(_child(p, 'pStyle'), 'val'),
          style = styles[id];
      final heading = RegExp(
        r'heading\s*([1-6])',
        caseSensitive: false,
      ).firstMatch('$id ${_attr(_child(style, 'name'), 'val')}');
      final name = heading == null ? 'p' : 'h${heading[1]}',
          align = _attr(_child(p, 'jc'), 'val'),
          body = all(),
          num = _child(p, 'numPr');
      final out =
          '<$name${['left', 'center', 'right', 'both'].contains(align) ? ' style="text-align:${align == 'both' ? 'justify' : align}"' : ''}>${body.isEmpty ? '<br>' : body}</$name>';
      if (num != null) {
        final kind = numbering[_attr(_child(num, 'numId'), 'val')] == 'bullet'
            ? 'ul'
            : 'ol';
        return '<$kind><li>$out</li></$kind>';
      }
      return out;
    }
    if (name == 'tbl') {
      return '<table>${node.childElements.where((n) => n.name.local == 'tr').map((n) => render(n, depth + 1)).join()}</table>';
    }
    if (name == 'tr') {
      return '<tr>${node.childElements.where((n) => n.name.local == 'tc').map((n) => render(n, depth + 1)).join()}</tr>';
    }
    if (name == 'tc') {
      final span =
          int.tryParse(
            _attr(_child(_child(node, 'tcPr'), 'gridSpan'), 'val'),
          ) ??
          1;
      return '<td${span > 1 && span < 100 ? ' colspan="$span"' : ''}>${all()}</td>';
    }
    if (name.endsWith('Pr') || ['instrText', 'del', 'sectPr'].contains(name)) {
      return '';
    }
    return all();
  }

  final body = _child(root, 'body');
  if (body == null) throw const FormatException('文档损坏或格式不受支持');
  final result = render(body);
  return result.isEmpty
      ? '<p></p>'
      : result.replaceAll('</ol><ol>', '').replaceAll('</ul><ul>', '');
}

String importRichDocument(({String extension, Uint8List bytes}) input) =>
    input.extension == 'rtf' ? rtfToHtml(input.bytes) : docxToHtml(input.bytes);
