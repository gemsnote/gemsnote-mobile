import 'package:flutter/material.dart';

class LanguageController extends ChangeNotifier {
  LanguageController({
    required this.load,
    required this.save,
    this.applyNative,
  });
  final Future<void> Function(String)? applyNative;
  Object? nativeError;
  final Future<String> Function() load;
  final Future<void> Function(String) save;
  String preference = 'system';
  bool _disposed = false;
  int _generation = 0;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool ready = false;
  Object? loadError;
  Locale? get locale => preference == 'system' ? null : Locale(preference);

  Future<void> restore() async {
    final generation = ++_generation;
    try {
      final value = await load();
      if (_disposed || generation != _generation) return;
      preference = {'system', 'en', 'zh'}.contains(value) ? value : 'system';
      loadError = null;
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      loadError = error;
    }
    if (_disposed) return;
    ready = true;
    notifyListeners();
    await refreshNative();
  }

  Future<void> refreshNative() async {
    final generation = _generation;
    try {
      await applyNative?.call(preference);
      if (_disposed || generation != _generation) return;
      nativeError = null;
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      nativeError = error;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> choose(String value) async {
    if (!{'system', 'en', 'zh'}.contains(value)) {
      throw ArgumentError.value(value);
    }
    final generation = ++_generation;
    await save(value);
    if (_disposed || generation != _generation) return;
    preference = value;
    ready = true;
    loadError = null;
    notifyListeners();
    await refreshNative();
  }
}

class LanguageScope extends InheritedNotifier<LanguageController> {
  const LanguageScope({
    super.key,
    required LanguageController controller,
    required super.child,
  }) : super(notifier: controller);
  static LanguageController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()?.notifier;
}
