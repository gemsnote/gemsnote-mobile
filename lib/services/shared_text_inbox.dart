import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SharedText {
  SharedText({
    required this.id,
    required this.title,
    required this.text,
    this.accountKey = '',
    this.resourceKind = '',
    this.resourceName = '',
    this.resourceSize = 0,
  }) {
    if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
        text.trim().isEmpty ||
        text.contains('\u0000') ||
        utf8.encode(text).length > 256 * 1024) {
      throw const FormatException('分享文本无效或超过 256 KiB');
    }
    if (hasResource &&
        (!{'image', 'attachment'}.contains(resourceKind) ||
            resourceName.isEmpty ||
            resourceName.length > 255 ||
            resourceName.contains(RegExp(r'[\\/\x00-\x1f\x7f]')) ||
            resourceName == '.' ||
            resourceName == '..' ||
            resourceSize <= 0 ||
            resourceSize > 32 * 1024 * 1024)) {
      throw const FormatException('分享资源信息无效或超过 32 MiB');
    }
    if (!hasResource && (resourceName.isNotEmpty || resourceSize != 0)) {
      throw const FormatException('分享资源类型缺失');
    }
  }
  final String id;
  final String title;
  final String text;
  final String accountKey;
  final String resourceKind, resourceName;
  final int resourceSize;
  bool get hasResource => resourceKind.isNotEmpty;

  factory SharedText.fromMap(Map<Object?, Object?> map) => SharedText(
    id: map['id'] as String,
    title: map['title'] as String? ?? '',
    text: map['text'] as String,
    accountKey: map['accountKey'] as String? ?? '',
    resourceKind: map['resourceKind'] as String? ?? '',
    resourceName: map['resourceName'] as String? ?? '',
    resourceSize: map['resourceSize'] as int? ?? 0,
  );

  String get suggestedTitle {
    final source = title.trim().isEmpty ? text.split('\n').first : title;
    final clean = source.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    return clean.isEmpty
        ? '分享的笔记'
        : String.fromCharCodes(clean.runes.take(200));
  }
}

/// Native Android/iOS storage owns the durable queue, even before login.
/// Entries are acknowledged only after import or explicit discard.
class SharedTextInbox extends ChangeNotifier {
  SharedTextInbox({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('gemsnote/shared_text'),
      supported =
          supported ??
          (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS));
  static final _handlerOwners = <(BinaryMessenger, String), SharedTextInbox>{};
  final MethodChannel _channel;
  final bool supported;
  SharedText? pending;
  String? error;
  bool _disposed = false;
  int _generation = 0;

  Future<void> start() async {
    if (!supported || _disposed) return;
    _handlerOwners[(_channel.binaryMessenger, _channel.name)] = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (!supported || _disposed) return;
    final generation = ++_generation;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('peek');
      if (_disposed || generation != _generation) return;
      pending = value == null ? null : SharedText.fromMap(value);
      error = null;
    } on MissingPluginException {
      // Other platforms and widget-only hosts do not register this channel.
      return;
    } on Object catch (failure) {
      if (_disposed || generation != _generation) return;
      error = '读取待处理分享失败：$failure';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> claim(SharedText item, String accountKey) => _channel
      .invokeMethod<void>('claim', {'id': item.id, 'accountKey': accountKey});

  Future<Uint8List> readResource(SharedText item, String accountKey) async {
    if (!item.hasResource) throw StateError('分享不包含资源');
    final bytes = await _channel.invokeMethod<Uint8List>('readResource', {
      'id': item.id,
      'accountKey': accountKey,
    });
    if (bytes == null || bytes.length != item.resourceSize) {
      throw StateError('分享资源不完整，请重新分享');
    }
    return bytes;
  }

  Future<void> acknowledge(SharedText item) async {
    await _channel.invokeMethod<void>('acknowledge', {'id': item.id});
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    final key = (_channel.binaryMessenger, _channel.name);
    if (supported && identical(_handlerOwners[key], this)) {
      _handlerOwners.remove(key);
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
