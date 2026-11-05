import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../domain/models/note_image_reference.dart';
import '../domain/models/body_image_references.dart';
import '../domain/models/note_history.dart';
import '../repositories/auth_repository.dart';
import 'note_reader_page.dart';

class NoteHistoryPage extends StatefulWidget {
  const NoteHistoryPage({
    super.key,
    required this.repository,
    required this.session,
    required this.note,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Note note;
  @override
  State<NoteHistoryPage> createState() => _NoteHistoryPageState();
}

class _NoteHistoryPageState extends State<NoteHistoryPage> {
  late Future<List<NoteHistory>> _histories;
  String? _loading;
  String? _error;
  bool _cachedOnly = false;
  @override
  void initState() {
    super.initState();
    _histories = _load();
  }

  Future<List<NoteHistory>> _load() => widget.repository.histories(
    widget.session,
    widget.note.noteId,
    cachedOnly: _cachedOnly,
  );

  Future<void> _restore(NoteHistory history, {bool withFiles = false}) async {
    if (_loading != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, withFiles ? 'historyRestoreFull' : 'm0248')),
        content: Text(
          trNow(context, withFiles ? 'historyRestoreFullConfirm' : 'm0249'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0250')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _loading = history.id;
      _error = null;
    });
    try {
      if (withFiles) {
        await widget.repository.restoreHistorySnapshot(
          widget.session,
          widget.note.noteId,
          history.id,
        );
      } else {
        await widget.repository.restoreHistory(
          widget.session,
          widget.note.noteId,
          history.id,
          cachedOnly: _cachedOnly,
          isMarkdown: history.isMarkdown,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0251', [error]));
    } finally {
      if (mounted) setState(() => _loading = null);
    }
  }

  Future<void> _open(NoteHistory history) async {
    if (_loading != null) return;
    setState(() {
      _loading = history.id;
      _error = null;
    });
    try {
      final content = await widget.repository.historyContent(
        widget.session,
        widget.note.noteId,
        history.id,
        cachedOnly: _cachedOnly,
      );
      if (!mounted) return;
      final imageIds = bodyImageIds(
        content,
        isMarkdown: widget.note.isMarkdown,
        server: widget.session.account.server,
      );
      bool isHistoryImage(Uri uri) => imageIds.contains(
        cachedImageFileId(uri, widget.session.account.server),
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NoteReaderPage(
            readOnly: true,
            safeHtmlPreview: true,
            loadCachedImage: (uri) async => isHistoryImage(uri)
                ? widget.repository.cachedHistoryImage(
                    widget.session,
                    widget.note.noteId,
                    history.id,
                    content,
                    widget.note.isMarkdown,
                    uri,
                  )
                : null,
            canDownloadImage: (uri) => !_cachedOnly && isHistoryImage(uri),
            downloadImage: _cachedOnly
                ? null
                : (uri) => widget.repository.downloadHistoryImage(
                    widget.session,
                    widget.note.noteId,
                    history.id,
                    content,
                    widget.note.isMarkdown,
                    uri,
                  ),
            note: widget.note.copyWith(
              content: content,
              updatedTime: history.updatedTime,
              title: trNow(context, 'm0252', [widget.note.title]),
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0253', [error]));
    } finally {
      if (mounted) setState(() => _loading = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'm0254'))),
    body: Column(
      children: [
        SwitchListTile(
          title: Text(tr(context, 'm0226')),
          subtitle: Text(tr(context, 'm0255')),
          value: _cachedOnly,
          onChanged: _loading != null
              ? null
              : (value) => setState(() {
                  _cachedOnly = value;
                  _error = null;
                  _histories = _load();
                }),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: FutureBuilder<List<NoteHistory>>(
            future: _histories,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(tr(context, 'm0256', [snapshot.error])),
                      TextButton(
                        onPressed: () => setState(() => _histories = _load()),
                        child: Text(tr(context, 'm0006')),
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snapshot.data!;
              if (items.isEmpty) {
                return Center(
                  child: Text(
                    _cachedOnly ? tr(context, 'm0257') : tr(context, 'm0258'),
                  ),
                );
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final history = items[index];
                  return ListTile(
                    key: ValueKey(history.id),
                    title: Text(history.updatedTime),
                    subtitle: Text(
                      tr(context, 'm0259', [history.updatedUserId]),
                    ),
                    trailing: _loading == history.id
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(),
                          )
                        : PopupMenuButton<String>(
                            enabled: _loading == null,
                            onSelected: (action) =>
                                _restore(history, withFiles: action == 'full'),
                            itemBuilder: (_) => [
                              if (!_cachedOnly && history.filesComplete)
                                PopupMenuItem(
                                  value: 'full',
                                  child: Text(
                                    tr(context, 'historyRestoreFull'),
                                  ),
                                ),
                              PopupMenuItem(
                                value: 'restore',
                                child: Text(tr(context, 'm0260')),
                              ),
                            ],
                          ),
                    onTap: _loading == null ? () => _open(history) : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}
