/// Stable, account-local tag choices. Filtering searches the complete set.
List<MapEntry<String, int>> tagChoices(
  Map<String, int> counts, {
  String query = '',
  Set<String> excluded = const {},
  int? limit,
  bool includeUnused = false,
}) {
  final key = query.trim().toLowerCase();
  final entries = counts.entries
      .where(
        (entry) =>
            (entry.value > 0 || (includeUnused && entry.value == 0)) &&
            entry.key.trim().isNotEmpty &&
            !excluded.contains(entry.key) &&
            entry.key.toLowerCase().contains(key),
      )
      .toList();
  entries.sort((a, b) {
    final count = b.value.compareTo(a.value);
    if (count != 0) return count;
    final name = a.key.toLowerCase().compareTo(b.key.toLowerCase());
    return name != 0 ? name : a.key.compareTo(b.key);
  });
  return limit == null ? entries : entries.take(limit).toList();
}
