class SharingRecipient {
  const SharingRecipient({
    required this.userId,
    required this.username,
    required this.noteIds,
  });
  final String userId;
  final String username;
  final List<String> noteIds;
  Map<String, Object?> toJson() => {
    'UserId': userId,
    'Username': username,
    'NoteIds': noteIds,
  };
}

class SharingNavigation {
  const SharingNavigation({
    this.recipients = const [],
    this.suggestions = const [],
    this.placements = const {},
  });
  final List<SharingRecipient> recipients;
  final List<SharingRecipient> suggestions;
  final Map<String, String> placements;
  List<String> recipientsFor(String noteId) => recipients
      .where((r) => r.noteIds.contains(noteId))
      .map((r) => r.username)
      .toList();
  Map<String, Object?> toJson() => {
    'Recipients': recipients.map((r) => r.toJson()).toList(),
    'Suggestions': suggestions.map((r) => r.toJson()).toList(),
    'Placements': placements,
  };
  factory SharingNavigation.fromJson(Map<String, Object?> data) {
    final ids = RegExp(r'^[a-fA-F0-9]{24}$');
    List<SharingRecipient> parse(Object? rawList) {
      final recipients = <SharingRecipient>[];
      for (final raw in (rawList as List? ?? const [])) {
        final row = Map<String, Object?>.from(raw as Map);
        final userId = row['UserId'] as String;
        final notes = (row['NoteIds'] as List? ?? []).cast<String>();
        if (!ids.hasMatch(userId) || notes.any((id) => !ids.hasMatch(id))) {
          throw const FormatException('invalidSharingNavigation');
        }
        recipients.add(
          SharingRecipient(
            userId: userId,
            username: row['Username'] as String,
            noteIds: notes,
          ),
        );
      }
      return recipients;
    }

    final recipients = parse(data['Recipients']);
    final suggestions = parse(data['Suggestions']);
    final placements = Map<String, String>.from(
      data['Placements'] as Map? ?? const {},
    );
    if (placements.entries.any(
      (e) => !ids.hasMatch(e.key) || !ids.hasMatch(e.value),
    )) {
      throw const FormatException('invalidSharingNavigation');
    }
    return SharingNavigation(
      recipients: recipients,
      suggestions: suggestions,
      placements: placements,
    );
  }
}
