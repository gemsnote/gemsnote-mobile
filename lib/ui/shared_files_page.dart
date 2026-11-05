import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/models/shared_file.dart';
import '../domain/models/shared_note.dart';
import '../repositories/auth_repository.dart';
import '../services/attachment_exporter.dart';
import '../services/attachment_opener.dart';
import '../services/attachment_sharer.dart';
import '../services/image_exporter.dart';

class SharedFilesPage extends StatefulWidget {
  const SharedFilesPage({
    super.key,
    required this.repository,
    required this.session,
    required this.note,
    required this.cachedOnly,
    this.attachmentExporter,
    this.attachmentOpener,
    this.attachmentSharer,
    this.imageExporter,
  });
  final AuthRepository repository;
  final StoredSession session;
  final SharedNote note;
  final bool cachedOnly;
  final AttachmentExporter? attachmentExporter;
  final AttachmentOpener? attachmentOpener;
  final AttachmentSharer? attachmentSharer;
  final ImageExporter? imageExporter;
  @override
  State<SharedFilesPage> createState() => _SharedFilesPageState();
}

class _SharedFilesPageState extends State<SharedFilesPage> {
  String? _busy;
  String? _error;

  Future<void> _act(SharedFile file, String action, Rect origin) async {
    if (_busy != null) return;
    final strings = AppStrings.snapshot(context);
    setState(() {
      _busy = file.fileId;
      _error = null;
    });
    try {
      final Uint8List bytes;
      if (widget.cachedOnly) {
        final cached = await widget.repository.cachedSharedFile(
          widget.session,
          widget.note,
          file,
        );
        if (cached == null) throw StateError(strings.text('m0356'));
        bytes = cached;
      } else {
        bytes = await widget.repository.downloadSharedFile(
          widget.session,
          widget.note,
          file,
        );
      }
      if (!mounted) return;
      switch (action) {
        case 'download':
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(trNow(context, 'm0357'))));
        case 'save':
          final saved = file.isAttachment
              ? await (widget.attachmentExporter ??
                        AttachmentExporter(
                          strings: AppStrings.snapshot(context),
                        ))
                    .save(file.title, bytes)
              : await (widget.imageExporter ??
                        ImageExporter(strings: AppStrings.snapshot(context)))
                    .save(file.title, bytes);
          if (mounted && saved) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(trNow(context, 'm0358'))));
          }
        case 'open':
          await (widget.attachmentOpener ??
                  AttachmentOpener(strings: AppStrings.snapshot(context)))
              .open(file.title, bytes, canOpen: () => mounted);
        case 'share':
          await (widget.attachmentSharer ??
                  AttachmentSharer(strings: AppStrings.snapshot(context)))
              .share(file.title, bytes, origin);
        case 'preview':
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: Text(file.title)),
                body: Center(
                  child: InteractiveViewer(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      cacheWidth: 2048,
                      errorBuilder: (_, _, _) => Text(trNow(context, 'm0359')),
                    ),
                  ),
                ),
              ),
            ),
          );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0360', [error]));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'm0361'))),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            widget.cachedOnly ? tr(context, 'm0362') : tr(context, 'm0363'),
          ),
        ),
        if (_busy != null) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: widget.note.files.isEmpty
              ? Center(child: Text(tr(context, 'm0364')))
              : ListView.builder(
                  itemCount: widget.note.files.length,
                  itemBuilder: (context, index) {
                    final file = widget.note.files[index];
                    final supported = file.size <= file.maxBytes;
                    return ListTile(
                      leading: Icon(
                        file.isAttachment
                            ? Icons.attach_file
                            : Icons.image_outlined,
                      ),
                      title: Text(
                        file.title.isEmpty ? file.fileId : file.title,
                      ),
                      subtitle: Text(
                        tr(context, 'm0366', [
                          file.size,
                          supported ? '' : tr(context, 'm0365'),
                        ]),
                      ),
                      trailing: Builder(
                        builder: (anchor) => PopupMenuButton<String>(
                          tooltip: tr(context, 'm0367'),
                          enabled: _busy == null && supported,
                          onSelected: (action) {
                            final box = anchor.findRenderObject();
                            if (box is RenderBox && box.hasSize) {
                              _act(
                                file,
                                action,
                                box.localToGlobal(Offset.zero) & box.size,
                              );
                            }
                          },
                          itemBuilder: (_) => [
                            if (!widget.cachedOnly)
                              PopupMenuItem(
                                value: 'download',
                                child: Text(tr(context, 'm0368')),
                              ),
                            if (!file.isAttachment)
                              PopupMenuItem(
                                value: 'preview',
                                child: Text(tr(context, 'm0369')),
                              ),
                            PopupMenuItem(
                              value: 'save',
                              child: Text(tr(context, 'm0370')),
                            ),
                            if (file.isAttachment)
                              PopupMenuItem(
                                value: 'open',
                                child: Text(tr(context, 'm0371')),
                              ),
                            PopupMenuItem(
                              value: 'share',
                              child: Text(tr(context, 'm0372')),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
