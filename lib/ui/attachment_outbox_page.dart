import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../data/database/attachment_outbox.dart';
import '../repositories/auth_repository.dart';
import '../services/attachment_exporter.dart';
import '../services/note_image_picker.dart';
import 'attachment_upload_dialog.dart';
import 'note_image_upload_dialog.dart';
import 'note_files_page.dart';

class AttachmentOutboxPage extends StatefulWidget {
  const AttachmentOutboxPage({
    super.key,
    required this.repository,
    required this.session,
    this.noteId,
    this.exporter,
  });
  final AuthRepository repository;
  final StoredSession session;
  final String? noteId;
  final AttachmentExporter? exporter;
  @override
  State<AttachmentOutboxPage> createState() => _AttachmentOutboxPageState();
}

class _AttachmentOutboxPageState extends State<AttachmentOutboxPage> {
  List<PendingAttachment> _items = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await widget.repository.pendingAttachments(
        widget.session,
        noteId: widget.noteId,
      );
      if (mounted) setState(() => _items = items);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0055'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(trNow(context, 'm0026')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(trNow(context, 'm0056')),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _action(PendingAttachment item, String action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (action == 'files') {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => NoteFilesPage(
              repository: widget.repository,
              session: widget.session,
              noteId: item.noteId,
            ),
          ),
        );
      } else if (action == 'remove') {
        if (await _confirm(
          trNow(context, 'm0057'),
          trNow(context, 'm0058', [item.name]),
        )) {
          await widget.repository.removeStagedAttachment(
            widget.session,
            item.id,
          );
        }
      } else if (action == 'recoverImage') {
        await widget.repository.recoverStagedImageUpload(
          widget.session,
          item.id,
        );
      } else if (action == 'cleanupImage') {
        if (await _confirm(
          trNow(context, 'cleanupImage'),
          trNow(context, 'cleanupImageConfirm'),
        )) {
          await widget.repository.cleanupStagedImageUpload(
            widget.session,
            item.id,
          );
        }
      } else if (action == 'insert') {
        await widget.repository.insertStagedImage(widget.session, item.id);
      } else if (action == 'retry') {
        if (await _confirm(
          trNow(context, 'm0059'),
          item.isImage
              ? trNow(context, 'm0060')
              : trNow(context, 'm0061', [item.name]),
        )) {
          await widget.repository.retryUncertainAttachment(
            widget.session,
            item.id,
          );
        }
      } else {
        final file = await widget.repository.stagedAttachment(
          widget.session,
          item.id,
        );
        if (!mounted) return;
        if (action == 'export') {
          await (widget.exporter ??
                  AttachmentExporter(strings: AppStrings.snapshot(context)))
              .save(file.name, file.bytes);
        } else if (action == 'upload' && item.isImage) {
          final image = await NoteImageUpload.normalize(file.bytes);
          if (!mounted) return;
          await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (_) => NoteImageUploadDialog(
              image: image,
              upload: () =>
                  widget.repository.uploadStagedImage(widget.session, item.id),
            ),
          );
        } else if (action == 'upload') {
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AttachmentUploadDialog(
              file: file,
              upload: () => widget.repository.uploadStagedAttachment(
                widget.session,
                item.id,
              ),
            ),
          );
        }
      }
      if (mounted) await _load();
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0062', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'm0063')),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: tr(context, 'm0064'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(12),
            child: Text(tr(context, 'm0065')),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                trMessage(context, _error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _items.isEmpty
                ? Center(child: Text(tr(context, 'm0066')))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (_, index) {
                      final item = _items[index];
                      return ListTile(
                        title: Text(item.name),
                        subtitle: Text(
                          tr(context, 'm0067', [
                            trLabel(context, item.statusLabel),
                            item.size,
                            item.noteId,
                          ]),
                        ),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          enabled: !_busy,
                          tooltip: tr(context, 'm0068'),
                          onSelected: (value) => _action(item, value),
                          itemBuilder: (_) => [
                            if (item.isImage &&
                                widget.session.account.supportsUploadReceipts &&
                                item.state == 'uncertain')
                              PopupMenuItem(
                                value: 'recoverImage',
                                child: Text(tr(context, 'recoverImage')),
                              ),
                            if (item.isImage &&
                                widget.session.account.supportsUploadReceipts &&
                                {'uploaded', 'cleaning'}.contains(item.state))
                              PopupMenuItem(
                                value: 'cleanupImage',
                                child: Text(tr(context, 'cleanupImage')),
                              ),
                            if (item.state == 'pending')
                              PopupMenuItem(
                                value: 'upload',
                                child: Text(
                                  item.isImage
                                      ? tr(context, 'm0069')
                                      : tr(context, 'm0070'),
                                ),
                              ),
                            if (item.state == 'uploaded')
                              PopupMenuItem(
                                value: 'insert',
                                child: Text(
                                  tr(
                                    context,
                                    item.isImage
                                        ? 'm0071'
                                        : 'bundleApplyReferences',
                                  ),
                                ),
                              ),
                            PopupMenuItem(
                              value: 'files',
                              child: Text(tr(context, 'm0072')),
                            ),
                            if (item.state == 'uncertain')
                              PopupMenuItem(
                                value: 'retry',
                                child: Text(tr(context, 'm0073')),
                              ),
                            PopupMenuItem(
                              value: 'export',
                              child: Text(tr(context, 'm0074')),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(tr(context, 'm0075')),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
