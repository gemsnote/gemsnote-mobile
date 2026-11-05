import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models/note.dart';
import '../repositories/auth_repository.dart';

class HomeWidgetAction {
  const HomeWidgetAction(this.id, this.account, this.action, this.noteId);
  final String id, account, action, noteId;
  factory HomeWidgetAction.fromMap(Map<Object?, Object?> value) {
    final id = value['id'] as String;
    final action = value['action'] as String;
    final noteId = value['noteId'] as String? ?? '';
    if (id.isEmpty ||
        !{'home', 'open', 'create'}.contains(action) ||
        (action == 'open' && !RegExp(r'^[a-fA-F0-9]{24}$').hasMatch(noteId))) {
      throw const FormatException('小组件入口无效');
    }
    return HomeWidgetAction(id, value['account'] as String, action, noteId);
  }
}

/// The native side also validates account and epoch, so late DB reads cannot
/// republish an account after logout/switch. iOS is intentionally unsupported.
class HomeWidgetController extends ChangeNotifier {
  HomeWidgetController({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('gemsnote/home_widget'),
      supported =
          supported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  final MethodChannel _channel;
  final bool supported;
  String _account = '', _epoch = '';
  int _generation = 0, _refreshGeneration = 0;
  bool _disposed = false;
  bool enabled = false, ready = false;
  String? error;
  HomeWidgetAction? pending;
  Future<void> _binding = Future.value();
  Future<void> activate(
    StoredSession? session,
    Future<List<Note>> Function()? load,
  ) {
    final generation = ++_generation;
    _account = session?.account.cacheKey ?? '';
    _epoch = '';
    ready = false;
    enabled = false;
    pending = null;
    if (!supported) return Future.value();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await peek();
    });
    final account = _account;
    // Serialize native activations even if user switches accounts rapidly.
    _binding = _binding.then((_) async {
      try {
        final result = await _channel.invokeMapMethod<String, Object?>(
          'activate',
          {'account': account},
        );
        if (_disposed || generation != _generation) return;
        _epoch = result!['epoch'] as String;
        enabled = result['enabled'] == true;
        ready = true;
        error = null;
      } on MissingPluginException {
        // Widget-only test hosts do not register native channels.
      } on Object catch (failure) {
        if (!_disposed && generation == _generation) {
          error = '小组件初始化失败：$failure';
        }
      }
      if (!_disposed && generation == _generation) notifyListeners();
    });
    return _binding.then((_) async {
      if (_disposed || generation != _generation || !ready) return;
      await peek();
      if (load != null) await refresh(account, load);
    });
  }

  static List<Map<String, String>> snapshot(List<Note> source) {
    final notes = source
        .where(
          (n) =>
              !n.isTrash &&
              !n.isDeleted &&
              RegExp(r'^[a-fA-F0-9]{24}$').hasMatch(n.noteId),
        )
        .toList();
    notes.sort((a, b) {
      final time = b.updatedTime.compareTo(a.updatedTime);
      return time != 0 ? time : a.noteId.compareTo(b.noteId);
    });
    return notes
        .take(30)
        .map(
          (note) => {
            'id': note.noteId,
            'title': String.fromCharCodes(
              note.title
                  .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
                  .runes
                  .take(160),
            ),
          },
        )
        .toList();
  }

  Future<void> refresh(
    String account,
    Future<List<Note>> Function() load,
  ) async {
    if (!supported || !ready || _disposed || account != _account || !enabled) {
      return;
    }
    final generation = _generation, read = ++_refreshGeneration, epoch = _epoch;
    try {
      final notes = snapshot(await load());
      if (_disposed ||
          generation != _generation ||
          read != _refreshGeneration ||
          !enabled) {
        return;
      }
      await _channel.invokeMethod<void>('publish', {
        'account': account,
        'epoch': epoch,
        'notes': notes,
      });
      if (!_disposed && generation == _generation) error = null;
    } on Object catch (failure) {
      if (!_disposed && generation == _generation) error = '刷新小组件失败：$failure';
    }
    if (!_disposed && generation == _generation) notifyListeners();
  }

  Future<void> setEnabled(
    bool value,
    Future<List<Note>> Function() load,
  ) async {
    if (!supported || !ready || _account.isEmpty) throw StateError('小组件尚未就绪');
    final generation = _generation, account = _account;
    await _channel.invokeMethod<void>('setEnabled', {
      'account': account,
      'epoch': _epoch,
      'enabled': value,
    });
    if (_disposed || generation != _generation) return;
    enabled = value;
    ++_refreshGeneration;
    notifyListeners();
    await refresh(account, load);
  }

  Future<void> peek() async {
    if (!supported || _disposed) return;
    final generation = _generation;
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>('peek');
      if (_disposed || generation != _generation) return;
      pending = result == null ? null : HomeWidgetAction.fromMap(result);
    } on MissingPluginException {
      return;
    } on Object catch (failure) {
      if (!_disposed && generation == _generation) error = '读取小组件操作失败：$failure';
    }
    if (!_disposed && generation == _generation) notifyListeners();
  }

  Future<void> acknowledge(HomeWidgetAction action) async {
    await _channel.invokeMethod<void>('acknowledge', {'id': action.id});
    if (pending?.id == action.id) pending = null;
  }

  @override
  void dispose() {
    _disposed = true;
    if (supported) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
