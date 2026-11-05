import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../domain/models/note.dart';
import 'markdown_note_body.dart';
import 'safe_html_note_body.dart';
import 'cached_markdown_image.dart';

class NoteReaderPage extends StatefulWidget {
  const NoteReaderPage({
    required this.note,
    this.onEdit,
    this.onSharedOrganize,
    this.loadSharing,
    this.loadCachedSharing,
    this.onManageSharing,
    this.onReviewCreation,
    this.onToggleStar,
    this.onMove,
    this.onCopy,
    this.onTrashToggle,
    this.onHistory,
    this.onDeleteForever,
    this.onEditTags,
    this.onFiles,
    this.onExport,
    this.onExportBundle,
    this.onSystemShare,
    this.loadCachedImage,
    this.downloadImage,
    this.canDownloadImage,
    this.readOnly = false,
    this.safeHtmlPreview = true,
    super.key,
  });

  final Note note;
  final Future<void> Function()? onSharedOrganize;
  final Future<List<String>> Function()? loadSharing;
  final Future<List<String>> Function()? loadCachedSharing;
  final Future<void> Function()? onManageSharing;
  final Future<bool> Function()? onReviewCreation;
  final Future<void> Function()? onEdit;
  final Future<void> Function()? onToggleStar;
  final Future<void> Function()? onMove;
  final Future<bool> Function()? onCopy;
  final Future<void> Function()? onTrashToggle;
  final Future<bool> Function()? onHistory;
  final Future<bool> Function()? onDeleteForever;
  final Future<bool> Function()? onEditTags;
  final Future<void> Function()? onFiles;
  final Future<bool> Function()? onExport;
  final Future<bool> Function()? onExportBundle;
  final Future<void> Function(Rect origin)? onSystemShare;
  final CachedImageLoader? loadCachedImage;
  final Future<Uint8List> Function(Uri)? downloadImage;
  final bool Function(Uri)? canDownloadImage;
  final bool readOnly;
  final bool safeHtmlPreview;

  @override
  State<NoteReaderPage> createState() => _NoteReaderPageState();
}

class _NoteReaderPageState extends State<NoteReaderPage> {
  WebViewController? _webView;
  bool _showSource = false;
  int _imageRevision = 0;
  bool _exporting = false;
  bool _sharing = false;
  bool _copying = false;
  bool _openingFiles = false;
  List<String> _recipients = [];
  Future<void> _loadSharing() async {
    try {
      final cached = await widget.loadCachedSharing?.call();
      if (mounted && cached != null) setState(() => _recipients = cached);
    } on Object {
      /* Still try refreshing if the local cache is unavailable. */
    }
    if (!mounted) return;
    try {
      final users = await widget.loadSharing?.call();
      if (mounted && users != null) setState(() => _recipients = users);
    } on Object {
      /* Keep the last cached sharing labels offline. */
    }
  }

  final _menuKey = GlobalKey();

  Future<void> _share() async {
    if (_sharing || widget.onSystemShare == null) return;
    setState(() => _sharing = true);
    try {
      final box = _menuKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        throw StateError(trNow(context, 'm0271'));
      }
      await widget.onSystemShare!(box.localToGlobal(Offset.zero) & box.size);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0272'))));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _export({bool bundle = false}) async {
    final export = bundle ? widget.onExportBundle : widget.onExport;
    if (_exporting || export == null) return;
    setState(() => _exporting = true);
    try {
      final saved = await export();
      if (mounted && saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0273'))));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              bundle
                  ? trNow(context, 'bundleExportFailed', [error])
                  : trNow(context, 'm0274'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSharing();
    if (!widget.note.isMarkdown && !widget.safeHtmlPreview) {
      _webView = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..setBackgroundColor(const Color(0xfff6f4eb))
        ..loadHtmlString(_htmlDocument(widget.note.content));
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return Scaffold(
      appBar: AppBar(
        title: Text(note.title.isEmpty ? tr(context, 'm0275') : note.title),
        actions: [
          if (note.isMarkdown || widget.safeHtmlPreview) ...[
            IconButton(
              tooltip: _showSource
                  ? tr(context, 'm0276')
                  : tr(context, 'm0277'),
              onPressed: () => setState(() => _showSource = !_showSource),
              icon: Icon(_showSource ? Icons.visibility_outlined : Icons.code),
            ),
            IconButton(
              tooltip: note.isMarkdown
                  ? tr(context, 'm0278')
                  : tr(context, 'm0279'),
              onPressed: () => copyNoteText(context, note.content),
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
          if (widget.readOnly && widget.onSharedOrganize != null)
            IconButton(
              tooltip: tr(context, 'moveCopyShared'),
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: widget.onSharedOrganize,
            ),
          if (widget.readOnly && widget.onFiles != null)
            IconButton(
              tooltip: tr(context, 'm0222'),
              icon: const Icon(Icons.attach_file),
              onPressed: _openingFiles
                  ? null
                  : () async {
                      setState(() => _openingFiles = true);
                      try {
                        await widget.onFiles!();
                      } finally {
                        if (mounted) {
                          setState(() {
                            _imageRevision++;
                            _openingFiles = false;
                          });
                        }
                      }
                    },
            ),
          if (!widget.readOnly) ...[
            IconButton(
              tooltip: tr(context, 'm0280'),
              onPressed: () async {
                await widget.onEdit?.call();
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.edit_outlined),
            ),
            PopupMenuButton<String>(
              key: _menuKey,
              onSelected: (value) async {
                switch (value) {
                  case 'manageSharing':
                    await widget.onManageSharing?.call();
                    await _loadSharing();
                    return;
                  case 'reviewCreation':
                    final recovered = await widget.onReviewCreation?.call();
                    if (recovered == true && context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return;
                  case 'copy':
                    if (_copying) return;
                    setState(() => _copying = true);
                    try {
                      final copied = await widget.onCopy?.call();
                      if (copied == true && context.mounted) {
                        Navigator.of(context).pop();
                      }
                    } finally {
                      if (mounted) setState(() => _copying = false);
                    }
                    return;
                  case 'systemShare':
                    await _share();
                    return;
                  case 'exportBundle':
                    await _export(bundle: true);
                    return;
                  case 'export':
                    await _export();
                    return;
                  case 'files':
                    await widget.onFiles?.call();
                    if (mounted) setState(() => _imageRevision++);
                    return;
                  case 'tags':
                    final saved = await widget.onEditTags?.call();
                    if (saved == true && context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return;
                  case 'deleteForever':
                    final deleted = await widget.onDeleteForever?.call();
                    if (deleted == true && context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return;
                  case 'history':
                    final restored = await widget.onHistory?.call();
                    if (restored == true && context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return;
                  case 'star':
                    await widget.onToggleStar?.call();
                  case 'move':
                    await widget.onMove?.call();
                  case 'trash':
                    await widget.onTrashToggle?.call();
                }
                if (context.mounted) Navigator.of(context).pop();
              },
              itemBuilder: (_) => [
                if (widget.onManageSharing != null)
                  PopupMenuItem(
                    value: 'manageSharing',
                    child: Text(tr(context, 'manageSharing')),
                  ),
                if (widget.onReviewCreation != null)
                  PopupMenuItem(
                    value: 'reviewCreation',
                    child: Text(tr(context, 'noteCreationTitle')),
                  ),
                if (widget.onSystemShare != null)
                  PopupMenuItem(
                    value: 'systemShare',
                    enabled: !_sharing,
                    child: Text(
                      _sharing ? tr(context, 'm0281') : tr(context, 'm0282'),
                    ),
                  ),
                if (widget.onExportBundle != null)
                  PopupMenuItem(
                    value: 'exportBundle',
                    enabled: !_exporting,
                    child: Text(tr(context, 'bundleExport')),
                  ),
                if (widget.onExport != null)
                  PopupMenuItem(
                    value: 'export',
                    enabled: !_exporting,
                    child: Text(
                      _exporting ? tr(context, 'm0283') : tr(context, 'm0284'),
                    ),
                  ),
                if (widget.onFiles != null)
                  PopupMenuItem(
                    value: 'files',
                    child: Text(tr(context, 'm0222')),
                  ),
                if (widget.onEditTags != null)
                  PopupMenuItem(
                    value: 'tags',
                    child: Text(tr(context, 'm0285')),
                  ),
                if (note.isTrash && widget.onDeleteForever != null)
                  PopupMenuItem(
                    value: 'deleteForever',
                    child: Text(tr(context, 'm0286')),
                  ),
                if (widget.onHistory != null)
                  PopupMenuItem(
                    value: 'history',
                    child: Text(tr(context, 'm0254')),
                  ),
                PopupMenuItem(
                  value: 'star',
                  child: Text(
                    note.isStarred
                        ? tr(context, 'm0287')
                        : tr(context, 'm0288'),
                  ),
                ),
                PopupMenuItem(value: 'move', child: Text(tr(context, 'm0289'))),
                if (!note.isTrash && widget.onCopy != null)
                  PopupMenuItem(
                    value: 'copy',
                    enabled: !_copying,
                    child: Text(
                      _copying ? tr(context, 'm0290') : tr(context, 'm0291'),
                    ),
                  ),
                PopupMenuItem(
                  value: 'trash',
                  child: Text(
                    note.isTrash ? tr(context, 'm0292') : tr(context, 'm0293'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Metadata(note: note),
          if (_recipients.isNotEmpty)
            Container(
              color: const Color(0xffebe8dc),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                tr(context, 'sharedWith', [_recipients.join(', ')]),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: note.isMarkdown
                ? _showSource
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(
                            note.content,
                            style: const TextStyle(fontSize: 16, height: 1.65),
                          ),
                        )
                      : MarkdownNoteBody(
                          key: ValueKey(_imageRevision),
                          content: note.content,
                          loadCachedImage: widget.loadCachedImage,
                          downloadImage: widget.downloadImage,
                          canDownloadImage: widget.canDownloadImage,
                        )
                : widget.safeHtmlPreview
                ? _showSource
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(note.content),
                        )
                      : SafeHtmlNoteBody(
                          key: ValueKey(_imageRevision),
                          content: note.content,
                          loadCachedImage: widget.loadCachedImage,
                          downloadImage: widget.downloadImage,
                          canDownloadImage: widget.canDownloadImage,
                        )
                : WebViewWidget(controller: _webView!),
          ),
          if (note.tags.isNotEmpty)
            Container(
              color: const Color(0xffebe8dc),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: note.tags
                    .map(
                      (tag) => Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
        ],
      ),
    );
  }

  static String _htmlDocument(String content) => '''<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body { margin: 20px; color: #222; background: #f6f4eb; font: 16px/1.65 sans-serif;
  overflow-wrap: anywhere; -webkit-user-select: text; user-select: text; }
img, video { max-width: 100%; height: auto; }
pre { overflow-x: auto; padding: 12px; background: #ebe8dc; }
table { max-width: 100%; border-collapse: collapse; }
td, th { border: 1px solid #ccc; padding: 6px; }
</style></head><body>$content</body></html>''';
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xffebe8dc),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      tr(context, 'm0294', [note.isMarkdown ? 'MD' : 'RT', note.updatedTime]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}
