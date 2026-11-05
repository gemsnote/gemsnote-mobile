import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/models/note_file.dart';
import '../repositories/auth_repository.dart';
import '../services/image_exporter.dart';
import '../services/attachment_exporter.dart';
import '../services/attachment_sharer.dart';
import '../services/attachment_opener.dart';
import '../services/file_cache_batch.dart';
import '../services/attachment_picker.dart';
import 'attachment_upload_dialog.dart';
import 'attachment_outbox_page.dart';

class NoteFilesPage extends StatefulWidget {
  const NoteFilesPage({
    super.key,
    required this.repository,
    required this.session,
    required this.noteId,
    this.imageExporter,
    this.attachmentExporter,
    this.attachmentPicker,
    this.attachmentSharer,
    this.attachmentOpener,
    this.initialCachedOnly = false,
  });
  final AuthRepository repository;
  final StoredSession session;
  final String noteId;
  final ImageExporter? imageExporter;
  final AttachmentExporter? attachmentExporter;
  final AttachmentPicker? attachmentPicker;
  final AttachmentSharer? attachmentSharer;
  final AttachmentOpener? attachmentOpener;
  final bool initialCachedOnly;
  @override
  State<NoteFilesPage> createState() => _NoteFilesPageState();
}

class _NoteFilesPageState extends State<NoteFilesPage> {
  List<NoteFile> _files = [];
  bool _loading = false;
  String? _opening;
  String? _error;
  bool _cachedOnly = false;
  int _generation = 0;
  FileCacheBatch? _batch;
  FileCacheProgress? _batchProgress;
  List<NoteFile> _failedFiles = [];
  String? _batchMessage;

  @override
  void dispose() {
    _batch?.cancel();
    super.dispose();
  }

  Future<void> _cacheFiles({bool retry = false}) async {
    if (_batch != null || _loading || _opening != null || _cachedOnly) return;
    final files = List<NoteFile>.of(retry ? _failedFiles : _files);
    if (files.isEmpty) return;
    final batch = FileCacheBatch();
    setState(() {
      _batch = batch;
      _batchMessage = null;
      _error = null;
      _failedFiles = [];
    });
    final result = await batch.run(
      files,
      download: (file) async {
        if (file.isAttachment) {
          await widget.repository.noteAttachment(
            widget.session,
            widget.noteId,
            file,
          );
        } else {
          await widget.repository.noteImage(
            widget.session,
            widget.noteId,
            file,
          );
        }
      },
      onProgress: (progress) {
        if (mounted) setState(() => _batchProgress = progress);
      },
    );
    if (!mounted) return;
    setState(() {
      _batch = null;
      _failedFiles = result.failed;
      _batchMessage = trNow(context, 'm0207', [
        result.cancelled ? trNow(context, 'm0205') : trNow(context, 'm0206'),
        result.completed,
        result.failed.length,
      ]);
    });
  }

  @override
  void initState() {
    super.initState();
    _cachedOnly = widget.initialCachedOnly;
    _load();
  }

  Future<void> _load() async {
    if (_opening != null || _batch != null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _files = [];
      _failedFiles = [];
      _batchProgress = null;
      _batchMessage = null;
    });
    try {
      final files = await widget.repository.noteFiles(
        widget.session,
        widget.noteId,
        cachedOnly: _cachedOnly,
      );
      if (mounted && generation == _generation) setState(() => _files = files);
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = trNow(context, 'm0208', [error]));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(NoteFile file) async {
    if (_opening != null || _batch != null || file.isAttachment) return;
    setState(() {
      _opening = file.id;
      _error = null;
    });
    try {
      final bytes = await widget.repository.noteImage(
        widget.session,
        widget.noteId,
        file,
        cachedOnly: _cachedOnly,
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => _ImagePreview(
            title: file.title,
            bytes: bytes,
            exporter:
                widget.imageExporter ??
                ImageExporter(strings: AppStrings.snapshot(context)),
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0082', [error]));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _uploadAttachment() async {
    if (_cachedOnly || _loading || _opening != null || _batch != null) return;
    setState(() => _opening = 'upload');
    try {
      final file =
          await (widget.attachmentPicker ??
                  AttachmentPicker(strings: AppStrings.snapshot(context)))
              .pick();
      if (!mounted || file == null) return;
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AttachmentUploadDialog(
          file: file,
          upload: () => widget.repository.uploadAttachment(
            widget.session,
            widget.noteId,
            file,
          ),
        ),
      );
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result ? trNow(context, 'm0209') : trNow(context, 'm0210'),
          ),
        ),
      );
      setState(() => _opening = null);
      await _load();
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0211', [error]));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _stageAttachment() async {
    if (_loading || _opening != null || _batch != null) return;
    setState(() => _opening = 'stage');
    try {
      final file =
          await (widget.attachmentPicker ??
                  AttachmentPicker(strings: AppStrings.snapshot(context)))
              .pick();
      if (file == null || !mounted) return;
      await widget.repository.stageAttachment(
        widget.session,
        widget.noteId,
        file,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0212'))));
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0213', [error]));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _openAttachment(NoteFile file) async {
    if (_loading || _opening != null || _batch != null || !file.isAttachment) {
      return;
    }
    setState(() {
      _opening = file.id;
      _error = null;
    });
    try {
      final bytes = await widget.repository.noteAttachment(
        widget.session,
        widget.noteId,
        file,
        cachedOnly: _cachedOnly,
      );
      if (!mounted) return;
      await (widget.attachmentOpener ??
              AttachmentOpener(strings: AppStrings.snapshot(context)))
          .open(file.title, bytes, canOpen: () => mounted);
    } on AttachmentOpenException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(
          () => _error = _cachedOnly
              ? trNow(context, 'm0214')
              : trNow(context, 'm0215'),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _shareAttachment(NoteFile file) async {
    if (_loading || _opening != null || _batch != null || !file.isAttachment) {
      return;
    }
    setState(() {
      _opening = file.id;
      _error = null;
    });
    try {
      final bytes = await widget.repository.noteAttachment(
        widget.session,
        widget.noteId,
        file,
        cachedOnly: _cachedOnly,
      );
      if (!mounted) return;
      // Resolve the current page bounds after download, including any rotation.
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        throw StateError(trNow(context, 'm0216'));
      }
      final origin = box.localToGlobal(Offset.zero) & box.size;
      await (widget.attachmentSharer ??
              AttachmentSharer(strings: AppStrings.snapshot(context)))
          .share(file.title, bytes, origin);
    } on Object {
      if (mounted) {
        setState(
          () => _error = _cachedOnly
              ? trNow(context, 'm0217')
              : trNow(context, 'm0218'),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _saveAttachment(NoteFile file) async {
    if (_opening != null || _batch != null) return;
    setState(() {
      _opening = file.id;
      _error = null;
    });
    try {
      final bytes = await widget.repository.noteAttachment(
        widget.session,
        widget.noteId,
        file,
        cachedOnly: _cachedOnly,
      );
      if (!mounted) return;
      final saved =
          await (widget.attachmentExporter ??
                  AttachmentExporter(strings: AppStrings.snapshot(context)))
              .save(file.title, bytes);
      if (mounted && saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0219'))));
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error = _cachedOnly
              ? trNow(context, 'm0220')
              : trNow(context, 'm0221'),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'm0222')),
      actions: [
        PopupMenuButton<String>(
          tooltip: tr(context, 'm0223'),
          enabled: !_loading && _opening == null && _batch == null,
          onSelected: (value) async {
            if (value == 'stage') {
              await _stageAttachment();
            }
            if (value == 'outbox' && context.mounted) {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => AttachmentOutboxPage(
                    repository: widget.repository,
                    session: widget.session,
                    noteId: widget.noteId,
                  ),
                ),
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'stage', child: Text(tr(context, 'm0224'))),
            PopupMenuItem(value: 'outbox', child: Text(tr(context, 'm0063'))),
          ],
        ),
        IconButton(
          tooltip: tr(context, 'm0070'),
          icon: const Icon(Icons.upload_file),
          onPressed:
              _cachedOnly || _loading || _opening != null || _batch != null
              ? null
              : _uploadAttachment,
        ),
        IconButton(
          tooltip: tr(context, 'm0225'),
          onPressed: _loading || _opening != null || _batch != null
              ? null
              : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        SwitchListTile(
          title: Text(tr(context, 'm0226')),
          subtitle: Text(tr(context, 'm0227')),
          value: _cachedOnly,
          onChanged: _opening != null || _batch != null
              ? null
              : (value) {
                  setState(() => _cachedOnly = value);
                  _load();
                },
        ),
        Padding(padding: EdgeInsets.all(12), child: Text(tr(context, 'm0228'))),
        if (_loading) const LinearProgressIndicator(),
        if (!_cachedOnly) ...[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(tr(context, 'm0229')),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed:
                    _loading ||
                        _opening != null ||
                        _batch != null ||
                        _files.isEmpty
                    ? null
                    : () => _cacheFiles(),
                icon: const Icon(Icons.download),
                label: Text(tr(context, 'm0230')),
              ),
              if (_failedFiles.isNotEmpty)
                TextButton(
                  onPressed: _batch != null
                      ? null
                      : () => _cacheFiles(retry: true),
                  child: Text(tr(context, 'm0231')),
                ),
              if (_batch != null)
                TextButton(
                  onPressed: () {
                    _batch?.cancel();
                    setState(() => _batchMessage = tr(context, 'm0232'));
                  },
                  child: Text(tr(context, 'm0233')),
                ),
            ],
          ),
        ],
        if (_batch != null && _batchProgress != null) ...[
          LinearProgressIndicator(
            value: _batchProgress!.total == 0
                ? 0
                : _batchProgress!.completed / _batchProgress!.total,
          ),
          Text(
            tr(context, 'm0234', [
              _batchProgress!.completed,
              _batchProgress!.total,
              _batchProgress!.failed,
            ]),
          ),
        ],
        if (_batchMessage != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(trMessage(context, _batchMessage!)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: !_loading && _files.isEmpty
              ? Center(
                  child: Text(
                    _error == null
                        ? tr(context, 'm0235')
                        : tr(context, 'm0236'),
                  ),
                )
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (_, index) {
                    final file = _files[index];
                    return ListTile(
                      leading: Icon(
                        file.isAttachment
                            ? Icons.attach_file
                            : Icons.image_outlined,
                      ),
                      title: Text(file.title.isEmpty ? file.id : file.title),
                      subtitle: Text(
                        file.isAttachment
                            ? tr(context, 'm0237', [file.type])
                            : tr(context, 'm0238', [file.type]),
                      ),
                      trailing: _opening == file.id
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(),
                            )
                          : file.isAttachment
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: tr(context, 'm0239'),
                                  icon: const Icon(Icons.open_in_new),
                                  onPressed: _opening != null || _batch != null
                                      ? null
                                      : () => _openAttachment(file),
                                ),
                                IconButton(
                                  tooltip: tr(context, 'm0240'),
                                  icon: const Icon(Icons.save_alt),
                                  onPressed: _opening != null || _batch != null
                                      ? null
                                      : () => _saveAttachment(file),
                                ),
                                IconButton(
                                  tooltip: tr(context, 'm0241'),
                                  icon: const Icon(Icons.share_outlined),
                                  onPressed: _opening != null || _batch != null
                                      ? null
                                      : () => _shareAttachment(file),
                                ),
                              ],
                            )
                          : null,
                      onTap: _opening != null || _batch != null
                          ? null
                          : () => file.isAttachment
                                ? _saveAttachment(file)
                                : _open(file),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({
    required this.title,
    required this.bytes,
    required this.exporter,
  });
  final String title;
  final Uint8List bytes;
  final ImageExporter exporter;
  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await widget.exporter.save(widget.title, widget.bytes);
      if (mounted && saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0242'))));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0243'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title.isEmpty ? tr(context, 'm0244') : widget.title),
      actions: [
        IconButton(
          tooltip: _saving ? tr(context, 'm0245') : tr(context, 'm0246'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_alt),
        ),
      ],
    ),
    body: Center(
      child: InteractiveViewer(
        child: Image(
          image: ResizeImage(
            MemoryImage(widget.bytes),
            width: 2048,
            height: 2048,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Text(tr(context, 'm0247')),
        ),
      ),
    ),
  );
}
