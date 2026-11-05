import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'messages.dart';
import 'error_codes.dart';
import '../core/api/api_exception.dart';

class AppStrings {
  const AppStrings(this.locale);
  final Locale locale;
  static const delegate = _AppStringsDelegate();
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ??
      const AppStrings(Locale('zh'));

  /// For event handlers and initialization, without an inherited dependency.
  static AppStrings snapshot(BuildContext context) {
    final localizations = context
        .findAncestorWidgetOfExactType<Localizations>();
    return localizations != null &&
            localizations.delegates.any(
              (delegate) => delegate is LocalizationsDelegate<AppStrings>,
            )
        ? AppStrings(localizations.locale)
        : const AppStrings(Locale('zh'));
  }

  static final _sourceKeys = {
    for (final entry in messages.entries) entry.value.$1: entry.key,
  };
  String label(String source) =>
      _sourceKeys.containsKey(source) ? text(_sourceKeys[source]!) : source;

  static final _patterns = [
    for (final entry in messages.entries)
      for (final source in [entry.value.$1, entry.value.$2])
        if (source.contains(RegExp(r'\{\d+\}')))
          _MessagePattern(entry.key, source),
  ];

  /// Only for application-generated status/error strings, never note content.
  String translateMessage(String source) {
    final key = errorMessageKeys[source];
    if (key != null) return text(key);
    for (final prefix in [
      'Bad state: ',
      'FormatException: ',
      'Unsupported operation: ',
      'Exception: ',
    ]) {
      if (source.startsWith(prefix)) {
        return errorMessage(source.substring(prefix.length));
      }
    }
    final exact = _sourceKeys[source];
    if (exact != null) return text(exact);
    for (final entry in messages.entries) {
      if (entry.value.$2 == source) return text(entry.key);
    }
    if (source.length > 4096) return source;
    for (final pattern in _patterns) {
      if (pattern.prefix.isNotEmpty && !source.startsWith(pattern.prefix)) {
        continue;
      }
      final match = pattern.regex.firstMatch(source);
      if (match == null) continue;
      final values = <int, String>{};
      var valid = true;
      for (var group = 0; group < pattern.indices.length; group++) {
        final index = pattern.indices[group];
        final value = match[group + 1]!;
        if (values.containsKey(index) && values[index] != value) {
          valid = false;
          break;
        }
        values[index] = value;
      }
      if (valid) {
        return text(
          pattern.key,
          List.generate(pattern.arguments, (index) => values[index] ?? ''),
        );
      }
    }
    return source;
  }

  /// Never expose raw transport URLs, tokens, platform details or English
  /// runtime prefixes as user-facing errors. Machine codes remain unchanged.
  String errorMessage(Object error) {
    String source;
    if (error is PlatformException) {
      final key = errorMessageKeys[error.code];
      if (key != null) return text(key);
      final message = error.message ?? '';
      final translated = translateMessage(message);
      return translated != message || _sourceKeys.containsKey(message)
          ? translated
          : text('errorNative');
    }
    if (error is ApiException) {
      final key = errorMessageKeys[error.code];
      if (key != null) return text(key);
      if (error.statusCode == 401) return text('errorSession');
      if (error.statusCode == 403) return text('errorPermission');
      if (error.statusCode == 404) return text('errorMissing');
    }
    source = error is StateError
        ? error.message
        : error is FormatException
        ? error.message
        : '$error';
    final translated = translateMessage(source);
    if (translated != source ||
        errorMessageKeys.containsKey(source) ||
        _sourceKeys.containsKey(source) ||
        messages.values.any((pair) => pair.$2 == source)) {
      return translated;
    }
    return text('errorGeneric');
  }

  String _argument(Object? value) =>
      value is Error || value is Exception ? errorMessage(value!) : '$value';

  String text(String key, [List<Object?> arguments = const []]) {
    final pair = messages[key];
    if (pair == null) throw ArgumentError.value(key, 'message');
    final template = locale.languageCode == 'zh' ? pair.$1 : pair.$2;
    return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
      final index = int.parse(match[1]!);
      return index < arguments.length ? _argument(arguments[index]) : match[0]!;
    });
  }
}

String tr(
  BuildContext context,
  String key, [
  List<Object?> arguments = const [],
]) => AppStrings.of(context).text(key, arguments);

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();
  @override
  bool isSupported(Locale locale) => {'zh', 'en'}.contains(locale.languageCode);
  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture(AppStrings(locale));
  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}

String trLabel(BuildContext context, String label) =>
    AppStrings.of(context).label(label);

String trNow(
  BuildContext context,
  String key, [
  List<Object?> arguments = const [],
]) => AppStrings.snapshot(context).text(key, arguments);

String trMessage(BuildContext context, String message) =>
    AppStrings.of(context).translateMessage(message);

class _MessagePattern {
  _MessagePattern(this.key, String source) {
    final output = StringBuffer('^');
    var end = 0;
    for (final match in RegExp(r'\{(\d+)\}').allMatches(source)) {
      final literal = source.substring(end, match.start);
      if (indices.isEmpty) prefix = literal;
      output.write(RegExp.escape(literal));
      output.write('(.*?)');
      final index = int.parse(match[1]!);
      indices.add(index);
      if (index >= arguments) arguments = index + 1;
      end = match.end;
    }
    output.write(RegExp.escape(source.substring(end)));
    output.write(r'$');
    regex = RegExp(output.toString(), dotAll: true);
  }
  final String key;
  final indices = <int>[];
  int arguments = 0;
  String prefix = '';
  late final RegExp regex;
}
