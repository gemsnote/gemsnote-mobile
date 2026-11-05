import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../domain/models/sharing_navigation.dart';
import '../repositories/auth_repository.dart';
import '../l10n/app_strings.dart';

class SharedByMePage extends StatefulWidget {
  const SharedByMePage({
    super.key,
    required this.repository,
    required this.session,
    required this.openNote,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Future<void> Function(Note) openNote;
  @override
  State<SharedByMePage> createState() => _SharedByMePageState();
}

class _SharedByMePageState extends State<SharedByMePage> {
  SharingNavigation _navigation = const SharingNavigation();
  List<Note> _notes = [];
  bool _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cached = await widget.repository.sharingNavigation(widget.session);
      final notes = await widget.repository.notes(
        widget.session.account.cacheKey,
      );
      if (!mounted) return;
      setState(() {
        _navigation = cached;
        _notes = notes.where((n) => !n.isShared).toList();
      });
      final fresh = await widget.repository.sharingNavigation(
        widget.session,
        refresh: true,
      );
      if (mounted) setState(() => _navigation = fresh);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = trNow(context, 'sharingRefreshFailed', [error]),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'sharedByMe')),
      actions: [
        IconButton(
          tooltip: tr(context, 'm0377'),
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _navigation.recipients.isEmpty
              ? Center(child: Text(tr(context, 'noOutgoingShares')))
              : ListView(
                  children: [
                    for (final recipient in _navigation.recipients)
                      ExpansionTile(
                        key: ValueKey(recipient.userId),
                        title: Text(recipient.username),
                        trailing: Text('${recipient.noteIds.length}'),
                        children: [
                          for (final note in _notes.where(
                            (n) => recipient.noteIds.contains(n.noteId),
                          ))
                            ListTile(
                              title: Text(note.title),
                              subtitle: Text(
                                '${note.isMarkdown ? 'MD' : 'RT'} ${note.updatedTime}',
                              ),
                              onTap: () async {
                                await widget.openNote(note);
                                if (mounted) await _load();
                              },
                            ),
                          if (recipient.noteIds.any(
                            (id) => !_notes.any((n) => n.noteId == id),
                          ))
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(tr(context, 'sharedNotesNotCached')),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}
