import 'dart:async';

class SyncCancelled implements Exception {
  const SyncCancelled();
  @override
  String toString() => 'syncCancelled';
}

/// Scoped to one operation, including callbacks using another API client.
/// Zone inheritance keeps parallel UI requests out of this cancellation scope.
class Cancellation {
  final _aborted = Completer<void>();
  static final _key = Object();
  static Cancellation? get current => Zone.current[_key] as Cancellation?;
  bool get cancelled => _aborted.isCompleted;
  Future<void> get whenCancelled => _aborted.future;
  void cancel() {
    if (!cancelled) _aborted.complete();
  }

  void check() {
    if (cancelled) throw const SyncCancelled();
  }

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});
  Future<T> bind<T>(Future<T> work) async {
    final result = await Future.any<T>([
      work,
      whenCancelled.then<T>((_) => throw const SyncCancelled()),
    ]);
    check();
    return result;
  }
}
