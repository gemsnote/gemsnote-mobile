class FileCacheUsage {
  const FileCacheUsage({
    required this.files,
    required this.bytes,
    this.pendingDownloads = 0,
  });
  final int files;
  final int bytes;
  final int pendingDownloads;

  String get sizeLabel => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
