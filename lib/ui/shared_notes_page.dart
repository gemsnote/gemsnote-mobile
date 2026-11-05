import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/shared_note.dart';
import '../domain/models/shared_file.dart';
import '../domain/models/note_image_reference.dart';
import '../repositories/auth_repository.dart';
import 'note_reader_page.dart';
import 'shared_files_page.dart';
import 'shared_note_destination_dialog.dart';

class SharedNotesPage extends StatefulWidget {
  const SharedNotesPage({
    super.key,
    required this.repository,
    required this.session,
    this.initialNoteId,
    this.initialCachedOnly = false,
    this.embedded = false,
  });
  final AuthRepository repository;
  final StoredSession session;
  final String? initialNoteId;
  final bool initialCachedOnly;
  final bool embedded;
  @override
  State<SharedNotesPage> createState() => _SharedNotesPageState();
}

class _SharedNotesPageState extends State<SharedNotesPage> {
  List<SharedNote> _notes = [];
  bool _loading = false;
  bool _organizing = false;
  String? _opening;
  String? _error;
  bool _cachedOnly = false;
  int _generation = 0;
  bool _initialOpened = false;

  Future<void> _moveOrCopy(
    SharedNote note, {
    BuildContext? readerContext,
  }) async {
    if (_organizing) return;
    _organizing = true;
    try {
      final books = (await widget.repository.notebooks(
        widget.session.account.cacheKey,
      )).where((b) => !b.isDeleted).toList();
      if (!mounted || (readerContext != null && !readerContext.mounted)) return;
      final choice = await showDialog<SharedNoteDestination>(
        context: readerContext ?? context,
        builder: (_) => SharedNoteDestinationDialog(notebooks: books),
      );
      if (choice == null) return;
      setState(() => _opening = note.note.noteId);
      if (choice.copy) {
        await widget.repository.copySharedNote(
          widget.session,
          note,
          choice.notebookId,
        );
      } else {
        await widget.repository.moveSharedNote(
          widget.session,
          note,
          choice.notebookId,
        );
      }
      if (readerContext != null && readerContext.mounted) {
        Navigator.pop(readerContext);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trNow(context, choice.copy ? 'm0665' : 'sharedMoved'),
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (readerContext != null && readerContext.mounted) {
        ScaffoldMessenger.of(readerContext).showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.snapshot(readerContext).errorMessage(error),
            ),
          ),
        );
      } else if (mounted) {
        setState(
          () => _error = AppStrings.snapshot(context).errorMessage(error),
        );
      }
    } finally {
      _organizing = false;
      if (mounted) {
        setState(
          () => _opening = readerContext?.mounted == true
              ? note.note.noteId
              : null,
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _cachedOnly = widget.initialCachedOnly;
    _load();
  }

  Future<void> _load() async {
    if (_opening != null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _notes = [];
    });
    try {
      final notes = await widget.repository.sharedNotes(
        widget.session,
        cachedOnly: _cachedOnly,
      );
      if (mounted && generation == _generation) {
        setState(() => _notes = notes);
        final initial = widget.initialNoteId;
        final target = initial == null
            ? null
            : notes.where((item) => item.note.noteId == initial).firstOrNull;
        if (!_initialOpened && initial != null) {
          _initialOpened = true;
          if (target == null) {
            setState(() => _error = trNow(context, 'deepLinkMissing'));
          } else {
            await _open(target);
          }
        }
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = trNow(context, 'm0373', [error]));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(SharedNote note) async {
    if (_opening != null) return;
    setState(() {
      _opening = note.note.noteId;
      _error = null;
    });
    try {
      final content = await widget.repository.sharedContent(
        widget.session,
        note,
        cachedOnly: _cachedOnly,
      );
      if (!mounted) return;
      SharedFile? image(Uri uri) {
        final id = cachedImageFileId(uri, widget.session.account.server);
        return note.files
            .where((file) => file.fileId == id && !file.isAttachment)
            .firstOrNull;
      }

      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (readerContext) => NoteReaderPage(
            onSharedOrganize: () =>
                _moveOrCopy(note, readerContext: readerContext),
            note: content,
            readOnly: true,
            safeHtmlPreview: true,
            loadCachedImage: (uri) async {
              final file = image(uri);
              return file == null
                  ? null
                  : widget.repository.cachedSharedFile(
                      widget.session,
                      note,
                      file,
                    );
            },
            canDownloadImage: (uri) =>
                !_cachedOnly &&
                image(uri) != null &&
                image(uri)!.size <= image(uri)!.maxBytes,
            downloadImage: _cachedOnly
                ? null
                : (uri) {
                    final file = image(uri);
                    if (file == null) {
                      return Future.error(StateError(trNow(context, 'm0374')));
                    }
                    return widget.repository.downloadSharedFile(
                      widget.session,
                      note,
                      file,
                    );
                  },
            onFiles: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => SharedFilesPage(
                  repository: widget.repository,
                  session: widget.session,
                  note: note,
                  cachedOnly: _cachedOnly,
                ),
              ),
            ),
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0375', [error]));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: !widget.embedded,
      title: Text(tr(context, 'm0376')),
      actions: [
        IconButton(
          tooltip: tr(context, 'm0377'),
          onPressed: _loading || _opening != null ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        SwitchListTile(
          title: Text(tr(context, 'm0226')),
          subtitle: Text(tr(context, 'm0378')),
          value: _cachedOnly,
          onChanged: _opening != null
              ? null
              : (value) {
                  setState(() => _cachedOnly = value);
                  _load();
                },
        ),
        Padding(padding: EdgeInsets.all(12), child: Text(tr(context, 'm0379'))),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: !_loading && _notes.isEmpty
              ? Center(
                  child: Text(
                    _error == null
                        ? (_cachedOnly
                              ? tr(context, 'm0380')
                              : tr(context, 'm0381'))
                        : tr(context, 'm0236'),
                  ),
                )
              : ListView.builder(
                  itemCount: _notes.length,
                  itemBuilder: (context, index) {
                    final shared = _notes[index];
                    return ListTile(
                      title: Text(
                        shared.note.title.isEmpty
                            ? tr(context, 'm0275')
                            : shared.note.title,
                      ),
                      subtitle: Text(
                        '${shared.note.isMarkdown ? 'MD' : 'RT'} ${shared.note.updatedTime}\n${tr(context, 'm0382', [shared.note.userId])}',
                      ),
                      trailing: _opening == shared.note.noteId
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(),
                            )
                          : IconButton(
                              tooltip: tr(context, 'moveCopyShared'),
                              onPressed: _opening == null
                                  ? () => _moveOrCopy(shared)
                                  : null,
                              icon: const Icon(Icons.drive_file_move_outline),
                            ),
                      onTap: _opening == null ? () => _open(shared) : null,
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
