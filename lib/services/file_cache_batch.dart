import '../core/async/cancellation.dart';
import '../domain/models/note_file.dart';

class FileCacheProgress {
  const FileCacheProgress(this.total, this.completed, this.failed);
  final int total;
  final int completed;
  final int failed;
}

class FileCacheResult {
  const FileCacheResult(this.completed, this.failed, this.cancelled);
  final int completed;
  final List<NoteFile> failed;
  final bool cancelled;
}

/// A page-scoped download queue. Cancellation stops scheduling new files;
/// already started requests finish through the repository's cache validation.
class FileCacheBatch {
  bool _cancelled = false;
  bool _started = false;
  void cancel() => _cancelled = true;

  Future<FileCacheResult> run(
    List<NoteFile> files, {
    required Future<void> Function(NoteFile) download,
    void Function(FileCacheProgress)? onProgress,
  }) async {
    if (_started) throw StateError('batchAlreadyStarted');
    _started = true;
    final unique = <String, NoteFile>{};
    for (final file in files) {
      unique['${file.isAttachment}:${file.id}'] = file;
    }
    final queue = unique.values.toList(growable: false);
    final failed = <NoteFile>[];
    var next = 0;
    var completed = 0;
    void report() => onProgress?.call(
      FileCacheProgress(queue.length, completed, failed.length),
    );
    report();
    Future<void> worker() async {
      while (!_cancelled && next < queue.length) {
        final file = queue[next++];
        try {
          await download(file);
        } on SyncCancelled {
          cancel();
          break;
        } on Object {
          failed.add(file);
        }
        completed++;
        report();
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
    return FileCacheResult(completed, List.unmodifiable(failed), _cancelled);
  }
}
