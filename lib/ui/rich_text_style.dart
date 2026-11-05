import 'package:flutter/material.dart';

/// Deliberately small CSS vocabulary shared by the editor gate and native reader.
/// A rejected declaration is never rewritten into the saved source.
class RichTextStyle {
  const RichTextStyle(this.declarations);
  final Map<String, String> declarations;

  static RichTextStyle? parse(String source) {
    if (source.length > 2048) return null;
    final values = <String, String>{};
    for (final declaration in source.split(';')) {
      if (declaration.trim().isEmpty) continue;
      final parts = declaration.split(':');
      if (parts.length != 2) return null;
      final key = parts[0].trim().toLowerCase();
      final value = parts[1].trim().toLowerCase();
      final valid = switch (key) {
        'color' || 'background-color' => parseColor(value) != null,
        'font-size' => parseFontSize(value) != null,
        'font-family' => parseFontFamily(value) != null,
        'font-weight' => {
          'normal',
          'bold',
          '100',
          '200',
          '300',
          '400',
          '500',
          '600',
          '700',
          '800',
          '900',
        }.contains(value),
        'font-style' => {'normal', 'italic', 'oblique'}.contains(value),
        'text-align' => {
          'left',
          'right',
          'center',
          'justify',
          'start',
          'end',
        }.contains(value),
        'text-decoration' || 'text-decoration-line' =>
          value == 'none' ||
              (value.isNotEmpty &&
                  value
                      .split(RegExp(r'\s+'))
                      .every(
                        {'underline', 'line-through', 'overline'}.contains,
                      )),
        _ => false,
      };
      if (!valid) return null;
      values[key] = value;
    }
    return RichTextStyle(values);
  }

  TextAlign? get alignment => switch (declarations['text-align']) {
    'left' => TextAlign.left,
    'right' => TextAlign.right,
    'center' => TextAlign.center,
    'justify' => TextAlign.justify,
    'start' => TextAlign.start,
    'end' => TextAlign.end,
    _ => null,
  };

  TextStyle get textStyle {
    final weight = declarations['font-weight'];
    final decoration =
        declarations['text-decoration-line'] ?? declarations['text-decoration'];
    return TextStyle(
      color: parseColor(declarations['color'] ?? ''),
      backgroundColor: parseColor(declarations['background-color'] ?? ''),
      fontSize: parseFontSize(declarations['font-size'] ?? ''),
      fontFamily: parseFontFamily(declarations['font-family'] ?? ''),
      fontWeight: weight == null
          ? null
          : weight == 'bold'
          ? FontWeight.bold
          : weight == 'normal'
          ? FontWeight.normal
          : FontWeight.values[int.parse(weight) ~/ 100 - 1],
      fontStyle: declarations['font-style'] == null
          ? null
          : declarations['font-style'] == 'normal'
          ? FontStyle.normal
          : FontStyle.italic,
      decoration: decoration == null
          ? null
          : TextDecoration.combine([
              if (decoration.contains('underline')) TextDecoration.underline,
              if (decoration.contains('line-through'))
                TextDecoration.lineThrough,
              if (decoration.contains('overline')) TextDecoration.overline,
            ]),
    );
  }

  static double? parseFontSize(String value) {
    const named = {
      'xx-small': 10.0,
      'x-small': 12.0,
      'small': 14.0,
      'medium': 16.0,
      'large': 18.0,
      'x-large': 24.0,
      'xx-large': 32.0,
    };
    if (named.containsKey(value)) return named[value];
    final match = RegExp(r'^(\d+(?:\.\d+)?)(px|pt)$').firstMatch(value);
    if (match == null) return null;
    final size = double.parse(match[1]!) * (match[2] == 'pt' ? 4 / 3 : 1);
    return size >= 8 && size <= 72 ? size : null;
  }

  static String? parseFontFamily(String value) {
    // Only locally resolvable families; no CSS functions or arbitrary syntax.
    final families = value.split(',').map((part) => part.trim()).toList();
    const sans = {'sans-serif', 'arial', 'helvetica', 'verdana', 'tahoma'};
    const serif = {'serif', 'georgia', 'times new roman'};
    const mono = {'monospace', 'courier new'};
    String? first;
    for (var family in families) {
      if (family.length >= 2 &&
          ((family.startsWith('"') && family.endsWith('"')) ||
              (family.startsWith("'") && family.endsWith("'")))) {
        family = family.substring(1, family.length - 1);
      }
      final resolved = sans.contains(family)
          ? 'sans-serif'
          : serif.contains(family)
          ? 'serif'
          : mono.contains(family)
          ? 'monospace'
          : null;
      if (resolved == null) return null;
      first ??= resolved;
    }
    return first;
  }

  static Color? parseColor(String value) {
    const names = {
      'black': 0xff000000,
      'silver': 0xffc0c0c0,
      'gray': 0xff808080,
      'white': 0xffffffff,
      'maroon': 0xff800000,
      'red': 0xffff0000,
      'purple': 0xff800080,
      'fuchsia': 0xffff00ff,
      'green': 0xff008000,
      'lime': 0xff00ff00,
      'olive': 0xff808000,
      'yellow': 0xffffff00,
      'navy': 0xff000080,
      'blue': 0xff0000ff,
      'teal': 0xff008080,
      'aqua': 0xff00ffff,
      'orange': 0xffffa500,
      'transparent': 0x00000000,
    };
    if (names.containsKey(value)) return Color(names[value]!);
    if (RegExp(r'^#[0-9a-f]{3}$').hasMatch(value)) {
      final digits = value.substring(1).split('').map((d) => '$d$d').join();
      return Color(0xff000000 | int.parse(digits, radix: 16));
    }
    if (RegExp(r'^#[0-9a-f]{6}$').hasMatch(value)) {
      return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
    }
    final match = RegExp(r'^(rgb|rgba)\(([^()]*)\)$').firstMatch(value);
    if (match == null) return null;
    final parts = match[2]!.split(',').map((v) => v.trim()).toList();
    if (parts.length != (match[1] == 'rgb' ? 3 : 4)) return null;
    final rgb = parts.take(3).map(int.tryParse).toList();
    if (rgb.any((v) => v == null || v < 0 || v > 255)) return null;
    final alpha = parts.length == 4 ? double.tryParse(parts[3]) : 1.0;
    if (alpha == null || !alpha.isFinite || alpha < 0 || alpha > 1) return null;
    return Color.fromRGBO(rgb[0]!, rgb[1]!, rgb[2]!, alpha);
  }
}
