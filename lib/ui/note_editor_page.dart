import 'visual_editor_images.dart';
import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import 'cached_markdown_image.dart';
import 'markdown_editing.dart';
import 'markdown_note_body.dart';
import 'safe_html_note_body.dart';
import 'visual_html_editor.dart';
import 'editor_link_dialog.dart';
import '../services/note_image_picker.dart';
import 'note_image_upload_dialog.dart';

enum _VisualImageMode { offline, upload }

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    required this.note,
    required this.saveText,
    this.loadCachedImage,
    this.uploadImage,
    this.stageImage,
    this.stageVisualImage,
    this.pickImage,
    super.key,
  });

  final Note note;
  final Future<NoteImageUpload?> Function()? pickImage;
  final Future<void> Function(NoteImageUpload image)? stageImage;
  final Future<String> Function(NoteImageUpload image)? stageVisualImage;
  final Future<String> Function(NoteImageUpload image)? uploadImage;
  final Future<void> Function(String title, String content) saveText;
  // Preview is cache-only: editing arbitrary image URLs must never fetch them.
  final CachedImageLoader? loadCachedImage;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage>
    with WidgetsBindingObserver {
  late final TextEditingController _title;
  late final TextEditingController _content;
  var _allowPop = false;
  var _closing = false;
  Timer? _debounce;
  Future<bool>? _saving;
  late String _savedTitle;
  late String _savedContent;
  final _saveError = ValueNotifier<String?>(null);
  String? get _error => _saveError.value;
  bool _preview = false;
  final _contentFocus = FocusNode();
  final _titleFocus = FocusNode();
  final _titleUndo = UndoHistoryController();
  final _contentUndo = UndoHistoryController();
  bool _editingTitle = false;
  bool _linkDialogOpen = false;
  bool _insertingImage = false;
  bool get _busy => _closing || _insertingImage;

  @override
  void initState() {
    super.initState();
    // A valid initial selection lets Flutter record the original text before
    // the first edit (including a toolbar edit made before the field is focused).
    _title = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.note.title,
        selection: TextSelection.collapsed(offset: widget.note.title.length),
      ),
    );
    _content = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.note.content,
        selection: TextSelection.collapsed(offset: widget.note.content.length),
      ),
    );
    _savedTitle = widget.note.title;
    _savedContent = widget.note.content;
    _title.addListener(_changed);
    _content.addListener(_changed);
    _titleFocus.addListener(_trackFocus);
    _contentFocus.addListener(_trackFocus);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _contentFocus.dispose();
    _titleFocus.dispose();
    _titleUndo.dispose();
    _contentUndo.dispose();
    _title.dispose();
    _content.dispose();
    _saveError.dispose();
    super.dispose();
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _flush);
  }

  void _trackFocus() {
    if (_titleFocus.hasFocus || _contentFocus.hasFocus) {
      setState(() => _editingTitle = _titleFocus.hasFocus);
    }
  }

  Widget _historyButtons() {
    final history = _editingTitle ? _titleUndo : _contentUndo;
    return ValueListenableBuilder<UndoHistoryValue>(
      valueListenable: history,
      builder: (_, value, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: trNow(context, 'm0169'),
            onPressed: !_busy && value.canUndo ? history.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: trNow(context, 'm0170'),
            onPressed: !_busy && value.canRedo ? history.redo : null,
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _flush();
  }

  Future<bool> _flush() {
    _debounce?.cancel();
    return _saving ??= _drain().whenComplete(() => _saving = null);
  }

  Future<bool> _drain() async {
    while (mounted) {
      final title = _title.text;
      final content = _content.text;
      if (title == _savedTitle && content == _savedContent) return true;
      try {
        await widget.saveText(title, content);
        _savedTitle = title;
        _savedContent = content;
        if (mounted) setState(() => _saveError.value = null);
      } on Object catch (error) {
        if (mounted) {
          setState(() => _saveError.value = trNow(context, 'm0115', [error]));
        }
        return false;
      }
    }
    return false;
  }

  Future<void> _save() async {
    if (_allowPop || _busy) return;
    setState(() => _closing = true);
    final saved = await _flush();
    if (!mounted) return;
    if (!saved) {
      setState(() => _closing = false);
      return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _togglePreview() {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _preview = !_preview);
    _flush();
  }

  Future<void> _insertMarkdownLink() async {
    if (_busy || _linkDialogOpen) return;
    final original = _content.value;
    setState(() => _linkDialogOpen = true);
    try {
      final url = await showDialog<String>(
        context: context,
        builder: (_) => const EditorLinkDialog(),
      );
      if (!mounted || url == null) return;
      if (_content.text != original.text) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0171'))));
        return;
      }
      _content.value = insertMarkdownLink(original, url);
      _contentFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _linkDialogOpen = false);
    }
  }

  Future<VisualImageInsertion?> _pickVisualImage() async {
    final image =
        await (widget.pickImage ??
            NoteImagePicker(strings: AppStrings.snapshot(context)).pick)();
    if (!mounted || image == null) return null;
    final mode = widget.note.usn <= 0 && widget.stageVisualImage != null
        ? _VisualImageMode.offline
        : widget.stageVisualImage == null
        ? _VisualImageMode.upload
        : widget.uploadImage == null
        ? _VisualImageMode.offline
        : await showDialog<_VisualImageMode>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(tr(dialogContext, 'visualImageModeTitle')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(tr(dialogContext, 'm0026')),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, _VisualImageMode.offline),
                  child: Text(tr(dialogContext, 'visualImageOffline')),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, _VisualImageMode.upload),
                  child: Text(tr(dialogContext, 'visualImageUpload')),
                ),
              ],
            ),
          );
    if (!mounted || mode == null) return null;
    final reference = mode == _VisualImageMode.offline
        ? await widget.stageVisualImage!(image)
        : await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (_) => NoteImageUploadDialog(
              image: image,
              upload: () => widget.uploadImage!(image),
            ),
          );
    return reference == null
        ? null
        : VisualImageInsertion(reference, image.bytes);
  }

  Future<void> _insertImage() async {
    if (_busy || widget.uploadImage == null) return;
    final original = _content.value;
    setState(() => _insertingImage = true);
    try {
      final image =
          await (widget.pickImage ??
              NoteImagePicker(strings: AppStrings.snapshot(context)).pick)();
      if (!mounted || image == null) return;
      if (!await _flush() || !mounted) return;
      final reference = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => NoteImageUploadDialog(
          image: image,
          upload: () => widget.uploadImage!(image),
        ),
      );
      if (!mounted || reference == null) return;
      // Only API-created relative references may be written into the body.
      if (!RegExp(r'^/api2/file/getImage\?fileId=[0-9a-fA-F]{24}$')
          .hasMatch(reference)) {
        throw FormatException(trNow(context, 'm0172'));
      }
      // Insert after the selection, preserving selected text and all HTML.
      // HTML images are appended so a caret inside a tag cannot corrupt it.
      final offset =
          widget.note.isMarkdown &&
              _content.text == original.text &&
              original.selection.isValid
          ? original.selection.end.clamp(0, _content.text.length)
          : _content.text.length;
      final markup = widget.note.isMarkdown
          ? '\n![]($reference)\n'
          : '\n<img src="$reference" alt="">\n';
      _content.value = TextEditingValue(
        text: _content.text.replaceRange(offset, offset, markup),
        selection: TextSelection.collapsed(offset: offset + markup.length),
      );
      final saved = await _flush();
      if (mounted && saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0173'))));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0174', [error]))),
        );
      }
    } finally {
      if (mounted) setState(() => _insertingImage = false);
    }
  }

  Future<void> _stageImage() async {
    if (_busy || widget.stageImage == null) return;
    setState(() => _insertingImage = true);
    try {
      final image =
          await (widget.pickImage ??
              NoteImagePicker(strings: AppStrings.snapshot(context)).pick)();
      if (!mounted || image == null || !await _flush() || !mounted) return;
      await widget.stageImage!(image);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0175'))));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0176', [error]))),
        );
      }
    } finally {
      if (mounted) setState(() => _insertingImage = false);
    }
  }

  Widget _formatButton(
    String label,
    IconData icon,
    TextEditingValue Function(TextEditingValue) transform,
  ) => IconButton(
    tooltip: label,
    icon: Icon(icon),
    onPressed: _busy
        ? null
        : () {
            _content.value = transform(_content.value);
            _contentFocus.requestFocus();
          },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.note.isMarkdown ? tr(context, 'm0177') : tr(context, 'm0178'),
      ),
      actions: [
        if (!widget.note.isMarkdown)
          IconButton(
            tooltip: tr(context, 'm0179'),
            icon: const Icon(Icons.format_shapes),
            onPressed: _busy
                ? null
                : () async {
                    if (!supportsVisualHtml(_content.text)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr(context, 'm0180'))),
                      );
                      return;
                    }
                    _contentFocus.unfocus();
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => VisualHtmlEditor(
                          strings: AppStrings.of(context),
                          source: _content.text,
                          loadCachedImage: widget.loadCachedImage,
                          insertImage:
                              widget.uploadImage == null &&
                                  widget.stageVisualImage == null
                              ? null
                              : _pickVisualImage,
                          flush: _flush,
                          saveError: _saveError,
                          onChanged: (value) {
                            _content.text = value;
                          },
                        ),
                      ),
                    );
                    if (mounted) await _flush();
                  },
          ),
        IconButton(
          tooltip: _preview
              ? tr(context, 'm0181')
              : widget.note.isMarkdown
              ? tr(context, 'm0182')
              : tr(context, 'm0183'),
          onPressed: _busy ? null : _togglePreview,
          icon: Icon(
            _preview ? Icons.edit_outlined : Icons.visibility_outlined,
          ),
        ),
        IconButton(
          tooltip: tr(context, 'm0184'),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.check),
        ),
      ],
    ),
    body: PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _save();
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_error != null)
              MaterialBanner(
                content: Text(trMessage(context, _error!)),
                actions: [
                  TextButton(
                    onPressed: _flush,
                    child: Text(tr(context, 'm0006')),
                  ),
                ],
              ),
            TextField(
              focusNode: _titleFocus,
              undoController: _titleUndo,
              readOnly: _busy,
              controller: _title,
              autofocus: widget.note.title.isEmpty,
              decoration: InputDecoration(hintText: tr(context, 'm0185')),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (!widget.note.isMarkdown)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(tr(context, 'm0186')),
              ),
            if (!_preview)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _historyButtons(),
                    if (widget.stageImage != null)
                      IconButton(
                        tooltip: tr(context, 'm0187'),
                        icon: const Icon(Icons.add_photo_alternate),
                        onPressed: _busy ? null : _stageImage,
                      ),
                    if (widget.uploadImage != null)
                      IconButton(
                        tooltip: widget.note.isMarkdown
                            ? tr(context, 'm0188')
                            : tr(context, 'm0189'),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        onPressed: _busy ? null : _insertImage,
                      ),
                    if (widget.note.isMarkdown) ...[
                      _formatButton(
                        tr(context, 'm0190'),
                        Icons.format_bold,
                        (value) => toggleMarkdownWrap(value, '**'),
                      ),
                      _formatButton(
                        tr(context, 'm0191'),
                        Icons.format_italic,
                        (value) => toggleMarkdownWrap(value, '*'),
                      ),
                      _formatButton(
                        tr(context, 'm0192'),
                        Icons.code,
                        (value) => wrapMarkdown(value, '`'),
                      ),
                      PopupMenuButton<int>(
                        tooltip: tr(context, 'm0193'),
                        icon: const Icon(Icons.title),
                        enabled: !_busy,
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 0,
                            child: Text(tr(context, 'm0456')),
                          ),
                          for (var level = 1; level <= 6; level++)
                            PopupMenuItem(
                              value: level,
                              child: Text(tr(context, 'headingLevel', [level])),
                            ),
                        ],
                        onSelected: (level) {
                          if (_busy) return;
                          _content.value = setMarkdownHeading(
                            _content.value,
                            level,
                          );
                          _contentFocus.requestFocus();
                        },
                      ),
                      _formatButton(
                        tr(context, 'm0194'),
                        Icons.format_list_bulleted,
                        (value) => toggleMarkdownPrefixLines(value, '- '),
                      ),
                      _formatButton(
                        tr(context, 'm0195'),
                        Icons.format_list_numbered,
                        toggleMarkdownNumberedLines,
                      ),
                      _formatButton(
                        tr(context, 'm0196'),
                        Icons.format_quote,
                        (value) => toggleMarkdownPrefixLines(value, '> '),
                      ),
                      _formatButton(
                        tr(context, 'm0197'),
                        Icons.format_strikethrough,
                        (value) => wrapMarkdown(value, '~~'),
                      ),
                      _formatButton(
                        tr(context, 'm0198'),
                        Icons.code_outlined,
                        fenceMarkdownCode,
                      ),
                      _formatButton(
                        tr(context, 'm0199'),
                        Icons.check_box_outlined,
                        (value) => toggleMarkdownPrefixLines(value, '- [ ] '),
                      ),
                      _formatButton(
                        tr(context, 'm0119'),
                        Icons.table_chart_outlined,
                        (value) => insertMarkdownTable(
                          value,
                          template: tr(context, 'markdownTableTemplate'),
                        ),
                      ),
                      _formatButton(
                        tr(context, 'm0200'),
                        Icons.horizontal_rule,
                        (value) => insertMarkdownBlock(value, '---'),
                      ),
                      _formatButton(
                        tr(context, 'm0201'),
                        Icons.functions,
                        (value) => wrapMarkdown(value, r'$'),
                      ),
                      _formatButton(
                        tr(context, 'm0202'),
                        Icons.calculate_outlined,
                        fenceMarkdownMath,
                      ),
                      IconButton(
                        tooltip: tr(context, 'm0111'),
                        icon: const Icon(Icons.link),
                        onPressed: _busy || _linkDialogOpen
                            ? null
                            : _insertMarkdownLink,
                      ),
                    ],
                  ],
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: _preview ? 1 : 0,
                sizing: StackFit.expand,
                children: [
                  TextField(
                    undoController: _contentUndo,
                    focusNode: _contentFocus,
                    readOnly: _busy,
                    controller: _content,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: widget.note.isMarkdown
                          ? tr(context, 'm0203')
                          : tr(context, 'm0204'),
                      border: InputBorder.none,
                    ),
                  ),
                  if (_preview)
                    widget.note.isMarkdown
                        ? MarkdownNoteBody(
                            content: _content.text,
                            loadCachedImage: widget.loadCachedImage,
                          )
                        : SafeHtmlNoteBody(
                            content: _content.text,
                            loadCachedImage: widget.loadCachedImage,
                          )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
