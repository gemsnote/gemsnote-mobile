import 'package:url_launcher/url_launcher.dart';

/// Only explicit web addresses are eligible; never resolve against a server or
/// append session credentials. Native URL handlers receive only the note's URL.
Uri? externalNoteLink(String value) {
  if (value.isEmpty ||
      value.length > 8192 ||
      RegExp(r'^https?://[^/?#]*@', caseSensitive: false).hasMatch(value) ||
      RegExp(r'[\s\x00-\x20\x7f\\\u202a-\u202e\u2066-\u2069]')
          .hasMatch(value)) {
    return null;
  }
  try {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

class NoteLinkOpener {
  NoteLinkOpener({Future<bool> Function(Uri, LaunchMode)? launch})
    : _launch = launch ?? ((uri, mode) => launchUrl(uri, mode: mode));
  final Future<bool> Function(Uri, LaunchMode) _launch;

  Future<void> open(String value) async {
    final uri = externalNoteLink(value);
    if (uri == null) throw const FormatException('此地址不支持外部打开');
    if (!await _launch(uri, LaunchMode.externalApplication)) {
      throw StateError('未能打开外部应用');
    }
  }
}
