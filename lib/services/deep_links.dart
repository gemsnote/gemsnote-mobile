import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

enum DeepLinkKind { note, shared }

class DeepLinkTarget {
  const DeepLinkTarget({
    required this.kind,
    required this.noteId,
    required this.server,
    required this.userId,
  });

  final DeepLinkKind kind;
  final String noteId;
  final Uri server;
  final String userId;

  static DeepLinkTarget? parse(Uri link) {
    final segments = link.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    String? kindValue;
    String? noteId;
    Uri? server;
    if (link.scheme == 'gemsnote') {
      kindValue = link.host;
      if (segments.length != 1) return null;
      noteId = segments.single;
      server = Uri.tryParse(link.queryParameters['server'] ?? '');
    } else if ((link.scheme == 'https' || link.scheme == 'http') &&
        segments.length >= 3 &&
        segments[segments.length - 3] == 'app') {
      kindValue = segments[segments.length - 2];
      noteId = segments.last;
      final base = segments.take(segments.length - 3).join('/');
      server = _serverUri(link, base.isEmpty ? '/' : '/$base/');
    }
    final kind = switch (kindValue) {
      'note' => DeepLinkKind.note,
      'shared' => DeepLinkKind.shared,
      _ => null,
    };
    final userId = link.queryParameters['user'] ?? '';
    if (kind == null ||
        noteId == null ||
        !RegExp(r'^[a-fA-F0-9]{24}$').hasMatch(noteId) ||
        userId.isEmpty ||
        server == null ||
        !{'http', 'https'}.contains(server.scheme) ||
        server.host.isEmpty ||
        server.userInfo.isNotEmpty ||
        server.query.isNotEmpty ||
        server.fragment.isNotEmpty) {
      return null;
    }
    return DeepLinkTarget(
      kind: kind,
      noteId: noteId.toLowerCase(),
      server: _normalizeServer(server),
      userId: userId,
    );
  }

  static Uri _normalizeServer(Uri value) => _serverUri(
    value,
    value.path.endsWith('/') ? value.path : '${value.path}/',
  );

  static Uri _serverUri(Uri value, String path) => Uri(
    scheme: value.scheme,
    host: value.host,
    port:
        value.hasPort &&
            !((value.scheme == 'https' && value.port == 443) ||
                (value.scheme == 'http' && value.port == 80))
        ? value.port
        : null,
    path: path,
  );

  bool matches(Uri accountServer, String accountUserId) =>
      server == _normalizeServer(accountServer) && userId == accountUserId;
}

class DeepLinkController extends ChangeNotifier {
  DeepLinkController({Future<Uri?> Function()? initialLink, Stream<Uri>? links})
    : _initialLink = initialLink ?? AppLinks().getInitialLink,
      _links = links ?? AppLinks().uriLinkStream;

  final Future<Uri?> Function() _initialLink;
  final Stream<Uri> _links;
  StreamSubscription<Uri>? _subscription;
  DeepLinkTarget? pending;
  String? error;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subscription = _links.listen(_receive, onError: _failed);
    try {
      final initial = await _initialLink();
      if (initial != null) _receive(initial);
    } on Object catch (failure) {
      _failed(failure);
    }
  }

  void _receive(Uri link) {
    final target = DeepLinkTarget.parse(link);
    if (target == null) {
      error = 'invalidDeepLink';
    } else {
      pending = target;
      error = null;
    }
    notifyListeners();
  }

  void _failed(Object _) {
    error = 'deepLinkReadFailed';
    notifyListeners();
  }

  void acknowledge(DeepLinkTarget target) {
    if (identical(pending, target)) pending = null;
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
