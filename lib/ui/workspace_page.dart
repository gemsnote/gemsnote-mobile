import '../core/async/cancellation.dart';
import 'note_sharing_dialog.dart';
import 'shared_by_me_page.dart';
import 'note_creation_dialog.dart';
import 'notebook_conflict_dialog.dart';
import '../l10n/app_strings.dart';
import '../l10n/language_controller.dart';
import 'language_dialog.dart';

import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../domain/models/default_editor.dart';
import 'default_editor_dialog.dart';
import 'file_cache_dialog.dart';
import 'attachment_outbox_page.dart';
import '../domain/models/note_image_reference.dart';
import '../domain/models/note_sort.dart';
import '../domain/models/notebook.dart';
import '../domain/models/notebook_tree.dart';
import '../repositories/auth_repository.dart';
import '../services/note_exporter.dart';
import '../services/shared_text_inbox.dart';
import '../services/home_widget.dart';
import '../services/deep_links.dart';
import '../services/app_lock.dart';
import 'shared_text_dialog.dart';
import '../services/note_sharer.dart';
import '../services/account_file_cache.dart';
import '../services/background_tasks.dart';
import 'note_editor_page.dart';
import 'import_note_dialog.dart';
import 'note_reader_page.dart';
import 'note_files_page.dart';
import 'notebook_target_picker.dart';
import 'note_tags_dialog.dart';
import 'note_history_page.dart';
import 'note_search_page.dart';
import 'notebook_dialog.dart';
import 'notebook_creation_dialog.dart';
import 'move_notebook_dialog.dart';
import 'account_page.dart';
import 'account_switcher_page.dart';
import 'about_dialog.dart';
import 'account_avatar.dart';
import 'shared_notes_page.dart';
import 'tags_page.dart';
import 'sync_progress_dialog.dart';
import 'logout_confirmation_dialog.dart';
import 'reset_sync_dialog.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    required this.repository,
    required this.session,
    required this.onSignedOut,
    this.onSessionChanged,
    this.refreshAvatarOnStart = false,
    this.sharedTextInbox,
    this.homeWidget,
    this.deepLinks,
    this.appLock,
    super.key,
  });

  final AuthRepository repository;
  final StoredSession session;
  final VoidCallback onSignedOut;
  final ValueChanged<StoredSession>? onSessionChanged;
  final bool refreshAvatarOnStart;
  final SharedTextInbox? sharedTextInbox;
  final HomeWidgetController? homeWidget;
  final DeepLinkController? deepLinks;
  final AppLockController? appLock;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage>
    with WidgetsBindingObserver {
  bool _deepLinkBusy = false;

  void _deepLinkChanged() {
    if (_deepLinkBusy || !mounted || _signedOut || _loggingOut) return;
    final target = widget.deepLinks?.pending;
    if (target == null) return;
    _deepLinkBusy = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || _signedOut) return;
        final strings = AppStrings.snapshot(context);
        if (!target.matches(
          widget.session.account.server,
          widget.session.account.userId,
        )) {
          throw StateError(strings.text('deepLinkWrongAccount'));
        }
        widget.deepLinks!.acknowledge(target);
        if (target.kind == DeepLinkKind.shared) {
          if (!mounted) return;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SharedNotesPage(
                repository: widget.repository,
                session: widget.session,
                initialNoteId: target.noteId,
              ),
            ),
          );
          return;
        }
        var note = (await widget.repository.notes(
          widget.session.account.cacheKey,
        )).where((item) => item.noteId == target.noteId).firstOrNull;
        if (note == null) {
          await widget.repository.synchronize(widget.session);
          note = (await widget.repository.notes(
            widget.session.account.cacheKey,
          )).where((item) => item.noteId == target.noteId).firstOrNull;
        }
        if (note == null || note.isDeleted) {
          throw StateError(strings.text('deepLinkMissing'));
        }
        if (mounted) await _openReader(note);
      } on Object catch (failure) {
        widget.deepLinks?.acknowledge(target);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(trNow(context, 'deepLinkOpenFailed', [failure])),
            ),
          );
        }
      } finally {
        _deepLinkBusy = false;
        if (widget.deepLinks?.pending != null) _deepLinkChanged();
      }
    });
  }

  bool _widgetActionBusy = false;

  Future<List<Note>> _widgetNotes() =>
      widget.repository.notes(widget.session.account.cacheKey);

  void _homeWidgetChanged() {
    if (_widgetActionBusy || !mounted || _signedOut || _loggingOut) return;
    final action = widget.homeWidget?.pending;
    if (action == null) return;
    final strings = AppStrings.snapshot(context);
    _widgetActionBusy = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || _signedOut) return;
        // Let an open editor finish saving before handling a widget action.
        if (ModalRoute.of(context)?.isCurrent != true) return;
        await widget.homeWidget!.acknowledge(action);
        if (action.account != widget.session.account.cacheKey) {
          throw StateError(strings.text('m0466'));
        }
        if (action.action == 'open') {
          final notes = await _widgetNotes();
          final note = notes
              .where(
                (n) => n.noteId == action.noteId && !n.isTrash && !n.isDeleted,
              )
              .firstOrNull;
          if (note == null) throw StateError(strings.text('m0467'));
          if (mounted) await _openReader(note);
        } else if (action.action == 'create') {
          final books = await widget.repository.notebooks(
            widget.session.account.cacheKey,
          );
          if (books.isEmpty) throw StateError(strings.text('m0468'));
          if (!mounted) return;
          final target = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(trNow(context, 'm0469')),
              content: SizedBox(
                width: 360,
                height: 360,
                child: NotebookTargetPicker(
                  notebooks: books,
                  onSelected: (id) => Navigator.pop(context, id),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(trNow(context, 'm0026')),
                ),
              ],
            ),
          );
          if (!mounted || target == null) return;
          final editor = await widget.repository.defaultEditor(widget.session);
          final note = await widget.repository.createNote(
            widget.session,
            notebookId: target,
            isMarkdown: editor.isMarkdown,
          );
          if (mounted) await _editNote(note);
        } else {
          if (mounted) await _openAllNotes();
        }
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(trNow(context, 'm0470', [error]))),
          );
        }
      } finally {
        _widgetActionBusy = false;
        if (widget.homeWidget?.pending?.id != action.id) _homeWidgetChanged();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _configureHomeWidget() async {
    final controller = widget.homeWidget;
    if (controller == null || !controller.supported) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _HomeWidgetSettings(
        controller: controller,
        load: _widgetNotes,
        retry: () => controller.activate(widget.session, _widgetNotes),
      ),
    );
  }

  late Future<List<Notebook>> _notebooks;
  List<Note> _notes = const [];
  Notebook? _selectedNotebook;
  String? _selectedTag;
  int _selectedTab = 0;
  bool _sharedTabVisited = false;
  List<Note> _starredNotes = const [];
  bool get _showingStarred => _selectedTab == 1;
  var _showingTrash = false;
  var _showingAll = false;
  var _noteSort = NoteSort.updatedDescending;
  bool _sortBusy = false;
  String? _sortError;
  NoteSort? _sortRetry;

  Future<void> _loadNoteSort() async {
    if (_sortBusy) return;
    setState(() {
      _sortBusy = true;
      _sortError = null;
      _sortRetry = null;
    });
    try {
      final sort = await widget.repository.noteSort(widget.session);
      if (mounted) setState(() => _noteSort = sort);
    } on Object {
      if (mounted) setState(() => _sortError = trNow(context, 'm0471'));
    } finally {
      if (mounted) setState(() => _sortBusy = false);
    }
  }

  Future<void> _saveNoteSort(NoteSort sort) async {
    if (_sortBusy || _loggingOut || _signedOut) return;
    setState(() {
      _sortBusy = true;
      _sortError = null;
      _sortRetry = sort;
    });
    try {
      await widget.repository.setNoteSort(widget.session, sort);
      if (mounted) {
        setState(() {
          _noteSort = sort;
          _sortRetry = null;
        });
      }
    } on Object {
      if (mounted) setState(() => _sortError = trNow(context, 'm0472'));
    } finally {
      if (mounted) setState(() => _sortBusy = false);
    }
  }

  var _syncing = false;
  var _loggingOut = false;
  Set<String> _pendingNoteIds = {};
  Set<String> _pendingNotebookIds = {};
  String? _syncError;
  int _pendingRead = 0;
  Uint8List? _avatar;
  int _avatarRead = 0;
  String? _avatarError;
  bool _refreshingAvatar = false;
  final _expandedNotebooks = <String>{};
  Timer? _autoSyncTimer;
  bool _autoSyncEnabled = false;
  bool _autoSyncPreferenceBusy = false;
  bool _signedOut = false;
  bool _accountOpen = false;
  bool _foreground = true;
  bool _autoCacheFiles = false;
  bool _cachePreferenceBusy = false;
  bool _cachePreferenceLoaded = false;

  Future<void> _loadCachePreference() async {
    if (_cachePreferenceBusy) return;
    setState(() => _cachePreferenceBusy = true);
    try {
      final enabled = await widget.repository.autoCacheFiles(widget.session);
      if (mounted && !_signedOut) {
        setState(() {
          _autoCacheFiles = enabled;
          _cachePreferenceLoaded = true;
        });
        unawaited(_restoreDownloadStatus());
        unawaited(_configureBackgroundCache(enabled));
      }
    } on Object {
      // Leave caching off until a successful read; the account menu offers retry.
    } finally {
      if (mounted) setState(() => _cachePreferenceBusy = false);
    }
  }

  Future<void> _toggleCachePreference() async {
    if (_cachePreferenceBusy ||
        !_cachePreferenceLoaded ||
        _loggingOut ||
        _signedOut) {
      return;
    }
    final enabled = !_autoCacheFiles;
    setState(() => _cachePreferenceBusy = true);
    try {
      await widget.repository.setAutoCacheFiles(widget.session, enabled);
      if (mounted && !_signedOut) {
        setState(() => _autoCacheFiles = enabled);
        if (!enabled) _fileQueue?.cancel();
        unawaited(_configureBackgroundCache(enabled));
      }
    } on Object {
      if (mounted && !_signedOut) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0473'))));
      }
    } finally {
      if (mounted) setState(() => _cachePreferenceBusy = false);
    }
  }

  Future<void> _configureBackgroundCache(bool enabled) async {
    try {
      await BackgroundResourceCache.setEnabled(enabled);
    } on Object catch (error) {
      if (mounted && !_signedOut) {
        setState(() => _fileStatus = trNow(context, 'm0484', [error]));
      }
    }
  }

  Future<void> _handoffBackgroundCache() async {
    try {
      await _fileTask;
      if (!mounted || _foreground || _signedOut || !_autoCacheFiles) return;
      await BackgroundResourceCache.resumeOnce();
    } on Object catch (error) {
      if (mounted && !_signedOut) {
        setState(() => _fileStatus = trNow(context, 'm0484', [error]));
      }
    }
  }

  AccountFileCache? _fileQueue;
  Future<void>? _fileTask;
  String? _fileStatus;
  int _downloadStatusGeneration = 0;

  Future<void> _restoreDownloadStatus() async {
    final generation = ++_downloadStatusGeneration;
    try {
      final status = await widget.repository.downloadQueueStatus(
        widget.session,
      );
      if (!mounted ||
          _signedOut ||
          _fileTask != null ||
          generation != _downloadStatusGeneration) {
        return;
      }
      if (!status.isEmpty) {
        setState(
          () => _fileStatus = trNow(context, 'm0474', [
            status.notes,
            status.files,
            status.failed,
          ]),
        );
      }
    } on Object {
      if (mounted &&
          !_signedOut &&
          _fileTask == null &&
          generation == _downloadStatusGeneration) {
        setState(() => _fileStatus = trNow(context, 'm0475'));
      }
    }
  }

  late final SharedTextInbox _shareInbox;
  bool _shareOpen = false;

  void _shareChanged() {
    if (mounted) setState(() {});
  }

  Widget get _shareButton => IconButton(
    tooltip: trNow(context, 'm0476'),
    icon: Badge(
      isLabelVisible: _shareInbox.pending != null || _shareInbox.error != null,
      child: const Icon(Icons.move_to_inbox_outlined),
    ),
    onPressed: _syncing || _loggingOut || _shareOpen ? null : _openSharedText,
  );

  Future<void> _openSharedText() async {
    if (_shareOpen || _syncing || _loggingOut || _signedOut) return;
    _shareOpen = true;
    try {
      await _shareInbox.refresh();
      if (_shareInbox.error != null) throw StateError(_shareInbox.error!);
      final source = _shareInbox.pending;
      if (!mounted) return;
      if (source == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0477'))));
        return;
      }
      final books = await widget.repository.notebooks(
        widget.session.account.cacheKey,
      );
      if (!mounted) return;
      final note = await showDialog<Note>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SharedTextDialog(
          source: source,
          notebooks: books,
          accountLabel:
              '${widget.session.account.username} · ${widget.session.account.server}',
          canImport:
              source.accountKey.isEmpty ||
              source.accountKey == widget.session.account.cacheKey,
          onImport: (edited, notebookId) async {
            await _shareInbox.claim(source, widget.session.account.cacheKey);
            final bytes = source.hasResource
                ? await _shareInbox.readResource(
                    source,
                    widget.session.account.cacheKey,
                  )
                : null;
            return widget.repository.importSharedText(
              widget.session,
              edited,
              notebookId,
              resourceBytes: bytes,
            );
          },
          onAcknowledge: () => _shareInbox.acknowledge(source),
        ),
      );
      if (note != null && mounted) {
        await _reloadNotes();
        await _refreshPending();
        if (mounted) await _openReader(note);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0478', [error]))),
        );
      }
    } finally {
      if (mounted) setState(() => _shareOpen = false);
    }
  }

  bool _cacheDialogOpen = false;

  Future<void> _openAttachmentOutbox() async {
    if (_accountOpen || _syncing || _loggingOut || _signedOut) return;
    _accountOpen = true;
    try {
      await _stopFileCache();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => AttachmentOutboxPage(
            repository: widget.repository,
            session: widget.session,
          ),
        ),
      );
      if (mounted) {
        await _reloadNotes();
        await _refreshPending();
      }
    } finally {
      _accountOpen = false;
    }
  }

  Future<void> _manageFileCache() async {
    if (_cacheDialogOpen || _syncing || _loggingOut || _signedOut) return;
    _cacheDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => FileCacheDialog(
          accountLabel:
              '${widget.session.account.username} · ${widget.session.account.server}',
          load: () async {
            await _stopFileCache();
            return widget.repository.fileCacheUsage(widget.session);
          },
          clear: () async {
            await widget.repository.clearFileCache(widget.session);
            _downloadStatusGeneration++;
            if (mounted) setState(() => _fileStatus = null);
          },
        ),
      );
    } finally {
      _cacheDialogOpen = false;
    }
  }

  Future<void> _stopFileCache() async {
    _fileQueue?.cancel();
    await _fileTask;
  }

  void _startFileCache() {
    if (_cacheDialogOpen ||
        _accountOpen ||
        !_autoCacheFiles ||
        _cachePreferenceBusy ||
        !_foreground ||
        _signedOut ||
        _loggingOut ||
        _fileTask != null) {
      return;
    }
    final queue = _fileQueue = widget.repository.fileCacheQueue(widget.session);
    _downloadStatusGeneration++;
    setState(() => _fileStatus = trNow(context, 'm0479'));
    _fileTask = (() async {
      try {
        final notes = await widget.repository.notes(
          widget.session.account.cacheKey,
        );
        await queue.run(
          notes.where((n) => n.usn > 0).map((n) => n.noteId).toList(),
          listFiles: (id) => widget.repository.noteFiles(widget.session, id),
          download: (id, file) async {
            if (file.isAttachment) {
              await widget.repository.noteAttachment(widget.session, id, file);
            } else {
              await widget.repository.noteImage(widget.session, id, file);
            }
          },
          onProgress: (notes, files, failures) {
            if (mounted) {
              setState(
                () => _fileStatus = trNow(context, 'm0480', [
                  notes,
                  files,
                  failures,
                ]),
              );
            }
          },
        );
        if (mounted) {
          setState(
            () => _fileStatus = trNow(context, 'm0483', [
              _fileStatus ?? trNow(context, 'm0481'),
              queue.cancelled
                  ? trNow(context, 'm0205')
                  : trNow(context, 'm0482'),
            ]),
          );
        }
      } on Object catch (error) {
        if (mounted) {
          setState(() => _fileStatus = trNow(context, 'm0484', [error]));
        }
      } finally {
        _fileQueue = null;
        _fileTask = null;
      }
    })();
  }

  @override
  void initState() {
    super.initState();
    widget.deepLinks?.addListener(_deepLinkChanged);
    _deepLinkChanged();
    widget.homeWidget?.addListener(_homeWidgetChanged);
    _homeWidgetChanged();
    _shareInbox = widget.sharedTextInbox ?? SharedTextInbox();
    _shareInbox.addListener(_shareChanged);
    unawaited(_shareInbox.start());
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _notebooks = widget.repository.notebooks(widget.session.account.cacheKey);
    _refreshPending();
    _refreshAvatarCache();
    unawaited(_loadNoteSort());
    unawaited(_loadCachePreference());
    unawaited(_loadAutoSyncPreference());
    if (widget.refreshAvatarOnStart) unawaited(_refreshRemoteAvatar());
  }

  @override
  void dispose() {
    widget.deepLinks?.removeListener(_deepLinkChanged);
    widget.homeWidget?.removeListener(_homeWidgetChanged);
    _fileQueue?.cancel();
    _autoSyncTimer?.cancel();
    _shareInbox.removeListener(_shareChanged);
    _shareInbox.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_shareInbox.refresh());
    if (_foreground) unawaited(widget.homeWidget?.peek());
    unawaited(
      widget.homeWidget?.refresh(widget.session.account.cacheKey, _widgetNotes),
    );
    if (!_foreground) {
      _fileQueue?.cancel();
      if (_autoCacheFiles) unawaited(_handoffBackgroundCache());
      if (_autoSyncEnabled) unawaited(_handoffBackgroundSync());
    } else {
      unawaited(_configureBackgroundSync(false));
    }
    _scheduleAutoSync();
  }

  Future<void> _loadAutoSyncPreference() async {
    if (_autoSyncPreferenceBusy) return;
    setState(() => _autoSyncPreferenceBusy = true);
    try {
      final enabled = await widget.repository.autoSync(widget.session);
      if (mounted && !_signedOut) {
        setState(() => _autoSyncEnabled = enabled);
        _scheduleAutoSync();
        if (enabled && !_foreground) {
          unawaited(_handoffBackgroundSync());
        } else {
          unawaited(_configureBackgroundSync(false));
        }
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0506', [error]));
      }
    } finally {
      if (mounted) setState(() => _autoSyncPreferenceBusy = false);
    }
  }

  Future<void> _toggleAutoSync() async {
    if (_autoSyncPreferenceBusy || _signedOut || _loggingOut) return;
    setState(() => _autoSyncPreferenceBusy = true);
    try {
      final enabled = !_autoSyncEnabled;
      await widget.repository.setAutoSync(widget.session, enabled);
      if (mounted && !_signedOut) {
        setState(() => _autoSyncEnabled = enabled);
        _scheduleAutoSync();
        if (enabled && !_foreground) {
          unawaited(_handoffBackgroundSync());
        } else {
          unawaited(_configureBackgroundSync(false));
        }
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0506', [error]));
      }
    } finally {
      if (mounted) setState(() => _autoSyncPreferenceBusy = false);
    }
  }

  Future<void> _configureBackgroundSync(bool enabled) async {
    try {
      await BackgroundNoteSync.setEnabled(enabled);
    } on Object catch (error) {
      if (mounted && !_signedOut) {
        setState(() => _syncError = trNow(context, 'm0506', [error]));
      }
    }
  }

  Future<void> _handoffBackgroundSync() async {
    try {
      if (!mounted || _foreground || _signedOut || !_autoSyncEnabled) return;
      await BackgroundNoteSync.setEnabled(true);
      if (!mounted || _foreground || _signedOut || !_autoSyncEnabled) {
        await BackgroundNoteSync.setEnabled(false);
        return;
      }
      await BackgroundNoteSync.resumeOnce();
    } on Object catch (error) {
      if (mounted && !_signedOut) {
        setState(() => _syncError = trNow(context, 'm0506', [error]));
      }
    }
  }

  void _scheduleAutoSync() {
    _autoSyncTimer?.cancel();
    if (!_autoSyncEnabled || !_foreground || _signedOut) return;
    // Do not synchronize immediately on enable/resume. In particular, choosing
    // to skip synchronization at login remains meaningful.
    _autoSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || _signedOut || !_foreground || _syncing || _loggingOut) {
        return;
      }
      // Editors, readers, account pages and confirmation/menu routes must not
      // be interrupted by automatic refreshes of their underlying note data.
      if (ModalRoute.of(context)?.isCurrent != true) return;
      unawaited(_sync(automatic: true));
    });
  }

  Future<void> _refreshRemoteAvatar() async {
    if (_refreshingAvatar || _loggingOut) return;
    _refreshingAvatar = true;
    try {
      await widget.repository.refreshAccountPresentation(widget.session);
      if (!mounted) return;
      setState(() => _avatarError = null);
      await _refreshAvatarCache();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _avatarError = trNow(context, 'm0485', [error]));
      }
    } finally {
      _refreshingAvatar = false;
    }
  }

  Future<void> _refreshAvatarCache() async {
    final generation = ++_avatarRead;
    try {
      final bytes = await widget.repository.cachedAvatar(widget.session);
      if (mounted && generation == _avatarRead) {
        setState(() => _avatar = bytes);
      }
    } on Object catch (error) {
      if (mounted && generation == _avatarRead) {
        setState(() => _syncError = trNow(context, 'm0486', [error]));
      }
    }
  }

  Future<void> _openAccount() async {
    if (_syncing ||
        _loggingOut ||
        _signedOut ||
        _accountOpen ||
        _cacheDialogOpen) {
      return;
    }
    _accountOpen = true;
    try {
      await _stopFileCache();
      if (!mounted) return;
      final signedOut = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => AccountPage(
            repository: widget.repository,
            session: widget.session,
            appLock: widget.appLock,
          ),
        ),
      );
      if (signedOut == true && mounted) {
        _signedOut = true;
        _autoSyncTimer?.cancel();
        widget.onSignedOut();
        return;
      }
      if (mounted) await _refreshAvatarCache();
    } finally {
      _accountOpen = false;
    }
  }

  Future<void> _refreshPending() async {
    _homeWidgetChanged();
    if (!_signedOut) {
      unawaited(
        widget.homeWidget?.refresh(
          widget.session.account.cacheKey,
          _widgetNotes,
        ),
      );
    }
    final generation = ++_pendingRead;
    try {
      final ids = await widget.repository.pendingNoteIds(
        widget.session.account.cacheKey,
      );
      final books = await _notebooks;
      if (mounted && generation == _pendingRead) {
        setState(() {
          _pendingNoteIds = ids;
          _pendingNotebookIds = books
              .where((n) => n.isDirty)
              .map((n) => n.notebookId)
              .toSet();
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0487', [error]));
      }
    }
  }

  Widget _syncIcon() => Badge(
    isLabelVisible:
        _pendingNoteIds.isNotEmpty || _pendingNotebookIds.isNotEmpty,
    backgroundColor: const Color(0xffb9d9c4),
    child: const Icon(Icons.sync),
  );

  PreferredSizeWidget? get _syncStatus =>
      _syncError == null && _avatarError == null && _fileStatus == null
      ? null
      : PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Material(
            color: _syncError != null || _avatarError != null
                ? Theme.of(context).colorScheme.errorContainer
                : Theme.of(context).colorScheme.secondaryContainer,
            child: ListTile(
              dense: true,
              title: Text(
                _syncError ?? _avatarError ?? _fileStatus!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: trNow(context, 'm0488'),
                onPressed: () => setState(() {
                  _syncError = null;
                  _avatarError = null;
                  _fileStatus = null;
                }),
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        );

  Future<void> _openNotebook(Notebook notebook) async {
    final notes = await widget.repository.notes(
      widget.session.account.cacheKey,
      notebookId: notebook.notebookId,
    );
    if (mounted) {
      setState(() {
        _selectedNotebook = notebook;
        _showingAll = false;
        _selectedTag = null;
        _showingTrash = false;
        _notes = notes;
      });
    }
  }

  Future<void> _reloadNotes() async {
    if (mounted) {
      setState(() {
        _notebooks = widget.repository.notebooks(
          widget.session.account.cacheKey,
        );
      });
    }
    await _refreshPending();
    if (_showingStarred) {
      await _openStarred();
      return;
    }
    if (_showingAll) {
      await _openAllNotes();
      return;
    }
    if (_selectedTag != null) {
      final notes = await widget.repository.notesForTag(
        widget.session.account.cacheKey,
        _selectedTag!,
      );
      if (mounted) setState(() => _notes = notes);
      return;
    }
    if (_showingTrash) {
      final notes = await widget.repository.notes(
        widget.session.account.cacheKey,
        trashOnly: true,
      );
      if (mounted) setState(() => _notes = notes);
      return;
    }
    final notebook = _selectedNotebook;
    if (notebook != null) await _openNotebook(notebook);
  }

  Future<void> _openAllNotes() async {
    try {
      final notes = await widget.repository.notes(
        widget.session.account.cacheKey,
      );
      if (!mounted) return;
      setState(() {
        _selectedNotebook = null;
        _selectedTag = null;
        _showingTrash = false;
        _showingAll = true;
        _notes = notes;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0489', [error]));
      }
    }
  }

  Future<void> _openStarred() async {
    try {
      final notes = await widget.repository.notes(
        widget.session.account.cacheKey,
        starredOnly: true,
      );
      if (mounted) setState(() => _starredNotes = notes);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0489', [error]));
      }
    }
  }

  Future<void> _selectTab(int index) async {
    if (_selectedTab == index) return;
    setState(() {
      _selectedTab = index;
      if (index == 2) _sharedTabVisited = true;
    });
    if (index != 2) await _reloadNotes();
  }

  Future<void> _openTrash() async {
    _selectedTag = null;
    final notes = await widget.repository.notes(
      widget.session.account.cacheKey,
      trashOnly: true,
    );
    if (mounted) {
      setState(() {
        _selectedNotebook = null;
        _showingTrash = true;
        _showingAll = false;
        _notes = notes;
      });
    }
  }

  bool _exportingNotebook = false;
  Future<void> _exportNotebook(Notebook notebook) async {
    if (_exportingNotebook) return;
    final exporter = NoteExporter(strings: AppStrings.snapshot(context));
    setState(() => _exportingNotebook = true);
    try {
      final books = await widget.repository.notebooks(
        widget.session.account.cacheKey,
      );
      final notes = <Note>[];
      final queue = <String>[notebook.notebookId], seen = <String>{};
      var bytes = 0;
      for (var i = 0; i < queue.length; i++) {
        final id = queue[i];
        if (!seen.add(id)) throw StateError('笔记本层级异常，无法导出');
        if (seen.length > 3000) throw StateError('导出内容过大或笔记本层级过深，请分批导出');
        final batch = await widget.repository.notes(
          widget.session.account.cacheKey,
          notebookId: id,
        );
        for (final note in batch) {
          bytes += utf8.encode(note.content).length;
          notes.add(note);
          if (bytes > 128 * 1024 * 1024 || notes.length > 10000) {
            throw StateError('导出内容过大或笔记本层级过深，请分批导出');
          }
        }
        queue.addAll(
          books
              .where((b) => !b.isDeleted && b.parentNotebookId == id)
              .map((b) => b.notebookId),
        );
      }
      if (!mounted) return;
      final saved = await exporter.exportNotebook(notebook, books, notes);
      if (mounted && saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0273'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trNow(context, 'notebookExportFailed', [error])),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exportingNotebook = false);
    }
  }

  Future<void> _openReceivedShares([String? noteId]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SharedNotesPage(
          repository: widget.repository,
          session: widget.session,
          initialNoteId: noteId,
          initialCachedOnly: noteId != null,
        ),
      ),
    );
    if (mounted) await _reloadNotes();
  }

  Future<void> _openReader(Note note) async {
    if (note.isShared) {
      await _openReceivedShares(note.noteId);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (readerContext) => NoteReaderPage(
          note: note,
          loadCachedSharing: () async =>
              (await widget.repository.sharingNavigation(widget.session))
                  .recipientsFor(note.noteId),
          loadSharing: () async => (await widget.repository.sharingNavigation(
            widget.session,
            refresh: true,
          )).recipientsFor(note.noteId),
          onManageSharing: note.usn <= 0 || note.isTrash
              ? null
              : () => showDialog<void>(
                  context: readerContext,
                  barrierDismissible: false,
                  builder: (_) => NoteSharingDialog(
                    repository: widget.repository,
                    session: widget.session,
                    note: note,
                  ),
                ),
          onReviewCreation: note.usn != 0 || note.isTrash
              ? null
              : () async =>
                    await showDialog<bool>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => NoteCreationDialog(
                        load: () => widget.repository.reviewNoteCreation(
                          widget.session,
                          note.noteId,
                        ),
                        recover: (review) => widget.repository
                            .recoverNoteCreation(widget.session, review),
                      ),
                    ) ==
                    true,
          onExportBundle: () async {
            final exporter = NoteExporter(
              strings: AppStrings.snapshot(context),
            );
            final bundle = await widget.repository.exportBundle(
              widget.session,
              note,
            );
            if (!readerContext.mounted) return false;
            return exporter.exportBundle(bundle);
          },
          onExport: () async {
            final exporter = NoteExporter(
              strings: AppStrings.snapshot(context),
            );
            final books = await _notebooks;
            final names = books.where((b) => b.notebookId == note.notebookId);
            return exporter.export(
              note,
              notebook: names.isEmpty ? '' : names.first.title,
            );
          },
          onSystemShare: (origin) =>
              NoteSharer(strings: AppStrings.snapshot(context))
                  .share(note, origin),
          canDownloadImage: (uri) =>
              note.usn > 0 &&
              cachedImageFileId(uri, widget.session.account.server) != null,
          downloadImage: (uri) => widget.repository.downloadInlineImage(
            widget.session,
            note.noteId,
            uri,
          ),
          loadCachedImage: (uri) => widget.repository.cachedInlineImage(
            widget.session,
            note.noteId,
            uri,
          ),
          onFiles: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => NoteFilesPage(
                repository: widget.repository,
                session: widget.session,
                noteId: note.noteId,
                initialCachedOnly: note.usn <= 0,
              ),
            ),
          ),
          onHistory: note.usn == 0
              ? null
              : () async {
                  final restored = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => NoteHistoryPage(
                        repository: widget.repository,
                        session: widget.session,
                        note: note,
                      ),
                    ),
                  );
                  if (restored == true && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(trNow(context, 'm0490'))),
                    );
                  }
                  return restored == true;
                },
          onEdit: () => _editNote(note),
          onEditTags: () async =>
              await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => NoteTagsDialog(
                  tags: note.tags,
                  loadSuggestions: () => widget.repository.availableTags(
                    widget.session.account.cacheKey,
                  ),
                  onSave: (tags) => widget.repository.saveNoteTags(
                    widget.session,
                    note.noteId,
                    tags,
                  ),
                ),
              ) ==
              true,
          onDeleteForever: note.isTrash ? () => _deleteForever(note) : null,
          onToggleStar: () => _toggleStar(note),
          onMove: () => _moveNote(note),
          onCopy: () => _moveNote(note, copy: true),
          onTrashToggle: () => note.isTrash
              ? _saveMetadata(note.copyWith(isTrash: false))
              : _trashNote(note),
        ),
      ),
    );
    await _reloadNotes();
  }

  Future<bool> _deleteForever(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, 'm0491')),
        content: Text(trNow(context, 'm0492')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0286')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    try {
      await widget.repository.deleteTrash(widget.session, note.noteId);
      await _reloadNotes();
      return true;
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0493', [error]))),
        );
      }
      return false;
    }
  }

  Future<void> _openTags() async {
    final tag = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => TagsPage(
          repository: widget.repository,
          accountId: widget.session.account.cacheKey,
          session: widget.session,
        ),
      ),
    );
    if (tag == null || !mounted) return;
    try {
      final notes = await widget.repository.notesForTag(
        widget.session.account.cacheKey,
        tag,
      );
      if (!mounted) return;
      setState(() {
        _selectedTag = tag;
        _showingAll = false;
        _selectedNotebook = null;
        _showingTrash = false;
        _notes = notes;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0494', [error]));
      }
    }
  }

  Future<void> _search() async {
    final note = await Navigator.of(context).push<Note>(
      MaterialPageRoute(
        builder: (_) => NoteSearchPage(
          repository: widget.repository,
          session: widget.session,
        ),
      ),
    );
    if (note != null && mounted) await _openReader(note);
  }

  Future<void> _editNote(Note note) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          note: note,
          uploadImage: (image) async {
            await _stopFileCache();
            return widget.repository.uploadNoteImage(
              widget.session,
              note.noteId,
              image,
            );
          },
          stageImage: (image) async {
            await widget.repository.stageNoteImage(
              widget.session,
              note.noteId,
              image,
            );
          },
          stageVisualImage: (image) => widget.repository.stageVisualImage(
            widget.session,
            note.noteId,
            image,
          ),
          loadCachedImage: (uri) => widget.repository.cachedInlineImage(
            widget.session,
            note.noteId,
            uri,
          ),
          saveText: (title, content) => widget.repository.saveEditedText(
            widget.session,
            note.noteId,
            title,
            content,
          ),
        ),
      ),
    );
    await _reloadNotes();
  }

  Future<void> _saveMetadata(Note note) async {
    await widget.repository.saveNote(
      widget.session,
      note.copyWith(updatedTime: DateTime.now().toUtc().toIso8601String()),
    );
    await _reloadNotes();
  }

  Future<void> _toggleStar(Note note) =>
      _saveMetadata(note.copyWith(isStarred: !note.isStarred));

  Future<bool> _moveNote(Note note, {bool copy = false}) async {
    try {
      final notebooks = await widget.repository.notebooks(
        widget.session.account.cacheKey,
      );
      if (!mounted) return false;
      String? target;
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(
              copy ? trNow(context, 'm0291') : trNow(context, 'm0289'),
            ),
            content: SizedBox(
              width: 320,
              height: 320,
              child: NotebookTargetPicker(
                notebooks: notebooks,
                selected: target,
                canSelect: (id) => copy || id != note.notebookId,
                onSelected: (id) => update(() => target = id),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: target == null
                    ? null
                    : () => Navigator.pop(context, target),
                child: Text(
                  copy ? trNow(context, 'm0495') : trNow(context, 'm0168'),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(trNow(context, 'm0026')),
              ),
            ],
          ),
        ),
      );
      if (selected != null && copy) {
        await widget.repository.copyNote(widget.session, note, selected);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(trNow(context, 'm0496'))));
        }
        return true;
      }
      if (selected != null && selected != note.notebookId) {
        await _saveMetadata(note.copyWith(notebookId: selected));
        return true;
      }
      return false;
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0497', [error]))),
        );
      }
      return false;
    }
  }

  Future<void> _trashNote(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, 'm0293')),
        content: Text(
          trNow(context, 'm0498', [
            note.title.isEmpty ? trNow(context, 'm0275') : note.title,
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0293')),
          ),
        ],
      ),
    );
    if (confirmed == true) await _saveMetadata(note.copyWith(isTrash: true));
  }

  bool _createMenuOpen = false;

  Future<void> _chooseDefaultEditor() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DefaultEditorDialog(
      load: () => widget.repository.defaultEditor(widget.session),
      save: (editor) =>
          widget.repository.setDefaultEditor(widget.session, editor),
    ),
  );

  Future<void> _showCreateMenu() async {
    if (_createMenuOpen ||
        _syncing ||
        _loggingOut ||
        _selectedNotebook == null) {
      return;
    }
    setState(() => _createMenuOpen = true);
    try {
      final editor = await widget.repository.defaultEditor(widget.session);
      if (!mounted) return;
      final alternate = editor == DefaultEditor.html
          ? DefaultEditor.markdown
          : DefaultEditor.html;
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: Text(trNow(context, 'm0499')),
                subtitle: Text(
                  trNow(context, 'm0500', [trLabel(context, editor.label)]),
                ),
                onTap: () => Navigator.pop(context, editor.name),
              ),
              ListTile(
                leading: Icon(
                  alternate.isMarkdown ? Icons.code : Icons.article_outlined,
                ),
                title: Text(
                  trNow(context, 'm0502', [
                    alternate.isMarkdown
                        ? " Markdown"
                        : trNow(context, 'm0501'),
                  ]),
                ),
                onTap: () => Navigator.pop(context, alternate.name),
              ),
            ],
          ),
        ),
      );
      if (!mounted || action == null) return;
      await _createNote(DefaultEditor.values.byName(action).isMarkdown);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0503', [error]))),
        );
      }
    } finally {
      if (mounted) setState(() => _createMenuOpen = false);
    }
  }

  Future<void> _createNote(bool isMarkdown) async {
    final notebook = _selectedNotebook;
    if (notebook == null) return;
    final note = await widget.repository.createNote(
      widget.session,
      notebookId: notebook.notebookId,
      isMarkdown: isMarkdown,
    );
    await _editNote(note);
  }

  Future<void> _importNote(Notebook book) async {
    final missingNotebook = trNow(context, 'm0504');
    if (_syncing || _loggingOut) return;
    final note = await showDialog<Note>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ImportNoteDialog(
        targetTitle: book.title,
        onImport: (source) async {
          final books = await widget.repository.notebooks(
            widget.session.account.cacheKey,
          );
          final targetId =
              books.any((item) => item.notebookId == book.notebookId)
              ? book.notebookId
              : await widget.repository.resolveNotebookId(
                  widget.session,
                  book.notebookId,
                );
          if (!books.any(
            (item) => item.notebookId == targetId && !item.isDeleted,
          )) {
            throw StateError(missingNotebook);
          }
          if (source.bundle != null) {
            return widget.repository.importBundle(
              widget.session,
              targetId,
              source.bundle!,
            );
          }
          return widget.repository.createNote(
            widget.session,
            notebookId: targetId,
            isMarkdown: source.isMarkdown,
            title: source.title,
            content: source.content,
          );
        },
      ),
    );
    if (note == null || !mounted) return;
    await _reloadNotes();
    await _refreshPending();
    if (mounted) await _openReader(note);
  }

  Future<void> _cancelSync() async {
    // Pause automatic retries, otherwise a deliberately cancelled download
    // would immediately restart in the foreground or the OS worker.
    _autoSyncTimer?.cancel();
    if (mounted) setState(() => _autoSyncEnabled = false);
    final stopping = widget.repository.cancelSync();
    try {
      await widget.repository.setAutoSync(widget.session, false);
    } finally {
      await stopping;
    }
    await _configureBackgroundSync(false);
  }

  Future<void> _sync({
    bool reset = false,
    bool full = false,
    bool automatic = false,
  }) async {
    if (_syncing ||
        _loggingOut ||
        _signedOut ||
        _accountOpen ||
        _cacheDialogOpen) {
      return;
    }
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      if (reset && !await confirmResetSync(context)) return;
      // Drain in-flight resource writes before replacing or merging snapshots.
      // Otherwise a late file list could repopulate a freshly reset cache.
      await _stopFileCache();
      if (!mounted) return;
      if (automatic) {
        await widget.repository.synchronize(widget.session);
      } else {
        await showSyncProgress(
          context,
          cancel: _cancelSync,
          synchronize: (progress) => reset
              ? widget.repository.resetFromServer(
                  widget.session,
                  onProgress: progress,
                )
              : full
              ? widget.repository.synchronizeFull(
                  widget.session,
                  onProgress: progress,
                )
              : widget.repository.synchronize(
                  widget.session,
                  onProgress: progress,
                ),
        );
      }
      if (!mounted) return;
      _notebooks = widget.repository.notebooks(widget.session.account.cacheKey);
      await _refreshAvatarCache();
      if (!mounted) return;
      if (reset) {
        _selectedNotebook = null;
        _selectedTag = null;
        _showingTrash = false;
        _notes = [];
        _showingAll = false;
        _expandedNotebooks.clear();
      }
      await _reloadNotes();
      unawaited(_refreshRemoteAvatar());
      if (mounted) _startFileCache();
      if (mounted && !automatic) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0505'))));
      }
    } on SyncCancelled {
      if (mounted) {
        _notebooks = widget.repository.notebooks(
          widget.session.account.cacheKey,
        );
        await _reloadNotes();
      }
    } on Object catch (error) {
      // Upload may have committed earlier notes or restored a stale deletion
      // before reporting the conflict. Reflect that local state immediately.
      try {
        if (mounted) await _reloadNotes();
      } on Object {
        // Keep the original sync error visible; the next refresh can retry.
      }
      if (mounted &&
          !(automatic &&
              error is StateError &&
              error.message == 'syncInProgress')) {
        setState(() => _syncError = trNow(context, 'm0506', [error]));
        if (!automatic) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(trNow(context, 'm0506', [error])),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      await _refreshPending();
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _switchAccount() async {
    if (_syncing ||
        _loggingOut ||
        _signedOut ||
        _accountOpen ||
        _cacheDialogOpen ||
        _shareOpen) {
      return;
    }
    _accountOpen = true;
    try {
      final session = await Navigator.push<StoredSession>(
        context,
        MaterialPageRoute(
          builder: (_) => AccountSwitcherPage(
            repository: widget.repository,
            current: widget.session,
            beforeLoad: _stopFileCache,
          ),
        ),
      );
      if (!mounted || session == null) return;
      _signedOut = true;
      _autoSyncTimer?.cancel();
      widget.onSessionChanged?.call(session);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0507'))));
      }
    } finally {
      _accountOpen = false;
    }
  }

  Future<void> _logout() async {
    if (_loggingOut || _syncing) return;
    setState(() => _loggingOut = true);
    try {
      await _stopFileCache();
      var leavePending = false;
      try {
        final pending = await widget.repository.pendingNoteIds(
          widget.session.account.cacheKey,
        );
        final pendingBooks = (await _notebooks).any((n) => n.isDirty);
        if (!mounted) return;
        if (pending.isNotEmpty || pendingBooks) {
          await showSyncProgress(
            context,
            cancel: _cancelSync,
            synchronize: (progress) => widget.repository.prepareLogout(
              widget.session,
              onProgress: progress,
            ),
          );
        }
      } on SyncCancelled {
        return;
      } on Object {
        if (!mounted) return;
        leavePending = await confirmUnsyncedLogout(context);
        if (!leavePending) return;
      }
      if (!mounted) return;
      await widget.repository.logout(
        widget.session,
        discardSessionWithPendingChanges: leavePending,
      );
      _signedOut = true;
      _autoSyncTimer?.cancel();
      unawaited(_configureBackgroundCache(false));
      unawaited(_configureBackgroundSync(false));
      if (mounted) widget.onSignedOut();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _syncError = trNow(context, 'm0508', [error]));
      }
    } finally {
      await _refreshPending();
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  Future<void> _moveNotebook(Notebook notebook) async {
    final parent = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MoveNotebookDialog(
        repository: widget.repository,
        session: widget.session,
        notebook: notebook,
      ),
    );
    if (parent == null || !mounted) return;
    final notebooks = await widget.repository.notebooks(
      widget.session.account.cacheKey,
    );
    if (!mounted) return;
    setState(() {
      _notebooks = Future.value(notebooks);
      final byId = {for (final n in notebooks) n.notebookId: n};
      var id = parent;
      final visited = <String>{};
      while (id.isNotEmpty && visited.add(id)) {
        _expandedNotebooks.add(id);
        id = byId[id]?.parentNotebookId ?? '';
      }
    });
    await _refreshPending();
  }

  Future<void> _deleteNotebook(Notebook notebook) async {
    if (_accountOpen || _syncing || _loggingOut || _signedOut) return;
    _accountOpen = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(trNow(context, 'm0672')),
          content: Text(trNow(context, 'm0673', [notebook.title])),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(trNow(context, 'm0026')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(trNow(context, 'm0672')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _syncing = true);
      try {
        await widget.repository.deleteNotebook(widget.session, notebook);
        if (!mounted) return;
        if (_selectedNotebook?.notebookId == notebook.notebookId) {
          _selectedNotebook = null;
          _notes = [];
        }
        setState(() {
          _expandedNotebooks.remove(notebook.notebookId);
          _notebooks = widget.repository.notebooks(
            widget.session.account.cacheKey,
          );
        });
        await _refreshPending();
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(trNow(context, 'm0674', [error]))),
          );
        }
      }
    } finally {
      _accountOpen = false;
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _recoverNotebook(Notebook notebook) async {
    if (_accountOpen || _syncing || _loggingOut || _signedOut) return;
    _accountOpen = true;
    try {
      await _stopFileCache();
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => notebook.usn > 0
            ? NotebookConflictDialog(
                repository: widget.repository,
                session: widget.session,
                notebook: notebook,
              )
            : NotebookCreationDialog(
                repository: widget.repository,
                session: widget.session,
                notebook: notebook,
              ),
      );
      if (mounted) await _reloadNotes();
    } finally {
      _accountOpen = false;
    }
  }

  Future<void> _editNotebook({Notebook? existing, String parentId = ''}) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NotebookDialog(
        repository: widget.repository,
        session: widget.session,
        existing: existing,
        parentNotebookId: parentId,
      ),
    );
    if (saved == true && mounted) {
      if (parentId.isNotEmpty) _expandedNotebooks.add(parentId);
      setState(() {
        _notebooks = widget.repository.notebooks(
          widget.session.account.cacheKey,
        );
      });
      await _refreshPending();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _selectedTab == 2 ? 1 : 0,
      children: [
        _buildPersonalPage(context),
        if (_sharedTabVisited)
          SharedNotesPage(
            repository: widget.repository,
            session: widget.session,
            embedded: true,
          )
        else
          const SizedBox.shrink(),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedTab,
      onDestinationSelected: _selectTab,
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.note_outlined),
          selectedIcon: Icon(Icons.note),
          label: tr(context, 'm0532'),
        ),
        NavigationDestination(
          icon: Icon(Icons.star_outline),
          selectedIcon: Icon(Icons.star),
          label: tr(context, 'm0533'),
        ),
        NavigationDestination(
          icon: Icon(Icons.share_outlined),
          selectedIcon: Icon(Icons.share),
          label: tr(context, 'm0534'),
        ),
      ],
    ),
  );

  Widget _buildPersonalPage(BuildContext context) {
    if (_selectedNotebook != null ||
        _showingAll ||
        _selectedTag != null ||
        _showingStarred ||
        _showingTrash) {
      return _buildNoteList(context);
    }
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/images/gemsnote_s.png', width: 32, height: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr(context, 'm0141'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xff173d38),
        bottom: _syncStatus,
        foregroundColor: Colors.white,
        actions: [
          if (_shareInbox.supported) _shareButton,
          IconButton(
            tooltip: tr(context, 'm0410'),
            onPressed: _openTags,
            icon: const Icon(Icons.label_outline),
          ),
          IconButton(
            tooltip: tr(context, 'm0329'),
            onPressed: () => _editNotebook(),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: tr(context, 'm0509'),
            onSelected: (value) {
              if (value == 'homeWidget') _configureHomeWidget();
              if (value == 'language') {
                showDialog<void>(
                  context: context,
                  builder: (_) => const LanguageDialog(),
                );
              }
              if (value == 'defaultEditor') _chooseDefaultEditor();
              if (value == 'switchAccount') _switchAccount();
              if (value == 'account') {
                _openAccount();
              }
              if (value == 'sync') _sync();
              if (value == 'fullSync') _sync(full: true);
              if (value == 'resetSync') _sync(reset: true);
              if (value == 'autoSync') _toggleAutoSync();
              if (value == 'autoCache') {
                _toggleCachePreference();
              }
              if (value == 'retryCachePreference') _loadCachePreference();
              if (value == 'cacheFiles' && !_syncing && !_loggingOut) {
                _startFileCache();
              }
              if (value == 'stopCache') _fileQueue?.cancel();
              if (value == 'manageCache') _manageFileCache();
              if (value == 'attachmentOutbox') _openAttachmentOutbox();
              if (value == 'trash') _openTrash();
              if (value == 'about') {
                showDialog<void>(
                  context: context,
                  builder: (_) => const MobileAboutDialog(),
                );
              }
              if (value == 'logout') _logout();
            },
            itemBuilder: (_) => [
              if (widget.homeWidget?.supported == true)
                PopupMenuItem(
                  value: 'homeWidget',
                  child: Text(tr(context, 'm0510')),
                ),
              PopupMenuItem(
                value: 'account',
                child: Text(tr(context, 'm0034')),
              ),
              if (widget.onSessionChanged != null)
                PopupMenuItem(
                  value: 'switchAccount',
                  enabled: !_syncing && !_loggingOut,
                  child: Text(tr(context, 'm0511')),
                ),
              if (LanguageScope.maybeOf(context) != null)
                PopupMenuItem(
                  value: 'language',
                  child: Text(tr(context, 'languageTitle')),
                ),
              PopupMenuItem(
                value: 'defaultEditor',
                child: Text(tr(context, 'm0107')),
              ),
              PopupMenuItem(
                value: 'manageCache',
                child: Text(tr(context, 'm0125')),
              ),
              PopupMenuItem(
                value: 'attachmentOutbox',
                child: Text(tr(context, 'm0063')),
              ),
              PopupMenuItem(value: 'sync', child: Text(tr(context, 'm0512'))),
              PopupMenuItem(
                value: 'fullSync',
                child: Text(tr(context, 'm0513')),
              ),
              CheckedPopupMenuItem(
                value: 'autoCache',
                checked: _autoCacheFiles,
                enabled:
                    _cachePreferenceLoaded &&
                    !_cachePreferenceBusy &&
                    !_loggingOut,
                child: Text(tr(context, 'm0514')),
              ),
              if (!_cachePreferenceLoaded)
                PopupMenuItem(
                  value: 'retryCachePreference',
                  enabled: !_cachePreferenceBusy,
                  child: Text(
                    _cachePreferenceBusy
                        ? tr(context, 'm0515')
                        : tr(context, 'm0516'),
                  ),
                ),
              if (_autoCacheFiles && !_cachePreferenceBusy && _fileTask == null)
                PopupMenuItem(
                  value: 'cacheFiles',
                  child: Text(tr(context, 'm0517')),
                ),
              if (_fileTask != null)
                PopupMenuItem(
                  value: 'stopCache',
                  child: Text(tr(context, 'm0518')),
                ),
              CheckedPopupMenuItem(
                value: 'autoSync',
                checked: _autoSyncEnabled,
                enabled: !_autoSyncPreferenceBusy,
                child: Text(tr(context, 'm0519')),
              ),
              PopupMenuItem(
                value: 'resetSync',
                child: Text(tr(context, 'm0094')),
              ),
              PopupMenuItem(value: 'trash', child: Text(tr(context, 'm0520'))),
              PopupMenuItem(value: 'about', child: Text(tr(context, 'm0521'))),
              PopupMenuItem(value: 'logout', child: Text(tr(context, 'm0522'))),
            ],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: AccountAvatar(bytes: _avatar),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<Notebook>>(
        future: _notebooks,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(tr(context, 'm0523', [snapshot.error])));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final notebooks = snapshot.data!;
          final rows = NotebookTree(notebooks).visibleRows(_expandedNotebooks);
          return ListView.builder(
            itemCount: rows.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return ListTile(
                  leading: const Icon(Icons.notes),
                  title: Text(tr(context, 'm0524')),
                  onTap: _openAllNotes,
                );
              }
              if (index == 1) {
                return ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: Text(tr(context, 'sharedByMe')),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SharedByMePage(
                          repository: widget.repository,
                          session: widget.session,
                          openNote: _openReader,
                        ),
                      ),
                    );
                    if (mounted) await _reloadNotes();
                  },
                );
              }
              final row = rows[index - 2];
              final notebook = row.notebook;
              return ListTile(
                key: ValueKey(notebook.notebookId),
                contentPadding: EdgeInsets.only(
                  left: 8 + row.depth.clamp(0, 5) * 12.0,
                  right: 8,
                ),
                leading: row.hasChildren
                    ? IconButton(
                        tooltip:
                            _expandedNotebooks.contains(notebook.notebookId)
                            ? tr(context, 'm0525')
                            : tr(context, 'm0526'),
                        icon: Icon(
                          _expandedNotebooks.contains(notebook.notebookId)
                              ? Icons.expand_more
                              : Icons.chevron_right,
                        ),
                        onPressed: () => setState(() {
                          if (!_expandedNotebooks.remove(notebook.notebookId)) {
                            _expandedNotebooks.add(notebook.notebookId);
                          }
                        }),
                      )
                    : const SizedBox(
                        width: 48,
                        child: Icon(Icons.folder_outlined),
                      ),
                title: Tooltip(
                  message: notebook.title,
                  child: Text(
                    notebook.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (notebook.isDirty)
                      Tooltip(
                        message: tr(context, 'm0527'),
                        child: Icon(
                          Icons.circle,
                          size: 8,
                          color: Color(0xff173d38),
                        ),
                      ),
                    Text('${notebook.numberNotes}'),
                    PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'import') _importNote(notebook);
                        if (action == 'export') _exportNotebook(notebook);
                        if (action == 'rename') {
                          _editNotebook(existing: notebook);
                        }
                        if (action == 'child') {
                          _editNotebook(parentId: notebook.notebookId);
                        }
                        if (action == 'move') _moveNotebook(notebook);
                        if (action == 'delete') _deleteNotebook(notebook);
                        if (action == 'recoverCreation' ||
                            action == 'reviewConflict') {
                          _recoverNotebook(notebook);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'import',
                          enabled: !_syncing && !_loggingOut,
                          child: Text(tr(context, 'm0136')),
                        ),
                        PopupMenuItem(
                          value: 'export',
                          enabled:
                              !_exportingNotebook && !_syncing && !_loggingOut,
                          child: Text(
                            tr(
                              context,
                              _exportingNotebook ? 'm0283' : 'notebookExport',
                            ),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'rename',
                          child: Text(tr(context, 'm0528')),
                        ),
                        PopupMenuItem(
                          value: 'child',
                          child: Text(tr(context, 'm0330')),
                        ),
                        PopupMenuItem(
                          value: 'move',
                          child: Text(tr(context, 'm0168')),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(tr(context, 'm0672')),
                        ),
                        if (notebook.usn > 0 && notebook.isDirty)
                          PopupMenuItem(
                            value: 'reviewConflict',
                            child: Text(tr(context, 'notebookReviewTitle')),
                          ),
                        if (notebook.usn == 0)
                          PopupMenuItem(
                            value: 'recoverCreation',
                            child: Text(tr(context, 'm0529')),
                          ),
                      ],
                    ),
                  ],
                ),
                onTap: () => _openNotebook(notebook),
              );
            },
          );
        },
      ),
      floatingActionButton: _syncing
          ? const FloatingActionButton(
              onPressed: null,
              child: CircularProgressIndicator(),
            )
          : FloatingActionButton(
              tooltip: _pendingNoteIds.isEmpty && _pendingNotebookIds.isEmpty
                  ? tr(context, 'm0512')
                  : _pendingNotebookIds.isEmpty
                  ? tr(context, 'm0530', [_pendingNoteIds.length])
                  : tr(context, 'm0531', [
                      _pendingNoteIds.length,
                      _pendingNotebookIds.length,
                    ]),
              onPressed: _sync,
              child: _syncIcon(),
            ),
    );
  }

  Widget _buildNoteList(BuildContext context) {
    final sortedNotes = _noteSort.apply(
      _showingStarred ? _starredNotes : _notes,
    );
    return Scaffold(
      appBar: AppBar(
        bottom: _syncStatus,
        automaticallyImplyLeading: false,
        leading: _showingStarred
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _selectedNotebook = null;
                  _selectedTag = null;
                  _showingTrash = false;
                  _showingAll = false;
                }),
              ),
        title: Text(
          _showingStarred
              ? trNow(context, 'm0533')
              : _showingAll
              ? trNow(context, 'm0524')
              : _selectedTag ??
                    (_showingTrash
                        ? trNow(context, 'm0520')
                        : _selectedNotebook!.title),
        ),
        actions: [
          if (_shareInbox.supported) _shareButton,
          PopupMenuButton<NoteSort>(
            tooltip: trNow(context, 'm0535'),
            icon: const Icon(Icons.sort),
            enabled: !_sortBusy && !_loggingOut,
            onSelected: _saveNoteSort,
            itemBuilder: (_) => [
              for (final sort in NoteSort.values)
                CheckedPopupMenuItem(
                  value: sort,
                  checked: sort == _noteSort,
                  child: Text(trLabel(context, sort.label)),
                ),
            ],
          ),
          IconButton(
            tooltip: _syncing
                ? trNow(context, 'm0408')
                : trNow(context, 'm0512'),
            onPressed: _syncing ? null : _sync,
            icon: _syncing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _syncIcon(),
          ),
          IconButton(
            tooltip: trNow(context, 'm0298'),
            onPressed: _search,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_sortBusy) const LinearProgressIndicator(),
          if (_sortError != null)
            ListTile(
              title: Text(trMessage(context, _sortError!)),
              trailing: TextButton(
                onPressed: _sortBusy
                    ? null
                    : () => _sortRetry == null
                          ? _loadNoteSort()
                          : _saveNoteSort(_sortRetry!),
                child: Text(trNow(context, 'm0536')),
              ),
            ),
          Expanded(
            child: sortedNotes.isEmpty
                ? _EmptyState(label: trNow(context, 'm0537'))
                : ListView.separated(
                    itemCount: sortedNotes.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final note = sortedNotes[index];
                      return ListTile(
                        leading: Icon(
                          note.isMarkdown ? Icons.code : Icons.article_outlined,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                note.title.isEmpty
                                    ? trNow(context, 'm0275')
                                    : note.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_pendingNoteIds.contains(note.noteId))
                              Tooltip(
                                message: trNow(context, 'm0538'),
                                child: Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.circle,
                                    size: 8,
                                    color: Color(0xff173d38),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          "${note.isMarkdown ? 'MD' : 'RT'} ${note.updatedTime}",
                          maxLines: 1,
                        ),
                        trailing: note.isShared
                            ? const Icon(Icons.lock_outline)
                            : IconButton(
                                tooltip: note.isStarred
                                    ? trNow(context, 'm0287')
                                    : trNow(context, 'm0288'),
                                onPressed: () => _toggleStar(note),
                                icon: Icon(
                                  note.isStarred
                                      ? Icons.star
                                      : Icons.star_outline,
                                  color: note.isStarred
                                      ? const Color(0xff816d32)
                                      : null,
                                ),
                              ),
                        onTap: () => _openReader(note),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton:
          _showingAll ||
              _selectedTag != null ||
              _showingStarred ||
              _showingTrash
          ? null
          : FloatingActionButton(
              onPressed: _createMenuOpen || _syncing || _loggingOut
                  ? null
                  : _showCreateMenu,
              child: const Icon(Icons.add),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/images/gemsnote_s.png', width: 72, height: 72),
        const SizedBox(height: 16),
        Text(
          tr(context, 'm0003'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(label),
      ],
    ),
  );
}

class _HomeWidgetSettings extends StatefulWidget {
  const _HomeWidgetSettings({
    required this.controller,
    required this.load,
    required this.retry,
  });
  final HomeWidgetController controller;
  final Future<List<Note>> Function() load;
  final Future<void> Function() retry;
  @override
  State<_HomeWidgetSettings> createState() => _HomeWidgetSettingsState();
}

class _HomeWidgetSettingsState extends State<_HomeWidgetSettings> {
  bool busy = false;
  String? error;
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on Object catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => AlertDialog(
      title: Text(tr(context, 'm0510')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tr(context, 'm0539')),
          SwitchListTile(
            title: Text(tr(context, 'm0540')),
            value: widget.controller.enabled,
            onChanged: busy || !widget.controller.ready
                ? null
                : (value) => run(
                    () => widget.controller.setEnabled(value, widget.load),
                  ),
          ),
          if (error != null || widget.controller.error != null)
            Text(trMessage(context, error ?? widget.controller.error!)),
          if (busy) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => run(widget.retry),
          child: Text(tr(context, 'm0541')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'm0010')),
        ),
      ],
    ),
  );
}
