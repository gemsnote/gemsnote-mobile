import 'cached_markdown_image.dart';
import 'visual_editor_images.dart';
import '../l10n/app_strings.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'editor_link_dialog.dart';
import 'editor_table_dialog.dart';
import 'editor_table_operations.dart';
import 'editor_save_guard.dart';
import 'visual_html_policy.dart';
export 'visual_html_policy.dart' show supportsVisualHtml;

String visualEditorDocument(
  String source, {
  AppStrings strings = const AppStrings(Locale('zh')),
  Map<String, String> cachedImages = const {},
}) {
  if (!supportsVisualHtml(source)) {
    throw ArgumentError('Unsupported rich text');
  }
  if (cachedImages.values.any(
        (value) =>
            !RegExp(r'^data:image/png;base64,[A-Za-z0-9+/]+=*$')
                .hasMatch(value),
      ) ||
      cachedImages.values.fold<int>(0, (size, value) => size + value.length) >
          8 * 1024 * 1024) {
    throw ArgumentError('Invalid cached image presentation');
  }
  // JSON + escaping '<' prevents a note from closing the inline script.
  final initial = jsonEncode(source).replaceAll('<', r'\u003c');
  return '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src data:; form-action 'none'; base-uri 'none'">
<style>body{font:17px sans-serif;margin:16px;line-height:1.6;color:#183c32}
#editor img{max-width:100%;height:auto;min-width:24px;min-height:24px;outline:1px solid #c5d1cb}
#editor{min-height:80vh;outline:none;overflow-wrap:anywhere}
blockquote{border-left:3px solid #527b68;margin-left:0;padding-left:12px}
table{border-collapse:collapse;max-width:100%;table-layout:fixed;width:100%}
td,th{border:1px solid #527b68;padding:6px;min-width:24px;overflow-wrap:anywhere}
th{background:#e5eee8}caption{font-weight:bold}</style>
</head><body><div id="editor" contenteditable="true"></div><script>
const editor = document.getElementById('editor');
const original = $initial;
// Presentation lives outside the editable DOM, so snapshots, tables and undo
// retain original src/alt attributes without embedded bytes or temporary IDs.
const imageStyles = document.createElement('style');
document.head.appendChild(imageStyles);
const cachedImages = new Map();
window.cacheImage = (source, data) => {
  if (!/^data:image\\/png;base64,[A-Za-z0-9+/]+=*\$/.test(data)) return;
  if (data.length > 8 * 1024 * 1024) return;
  cachedImages.delete(source);
  cachedImages.set(source, data);
  while (cachedImages.size > 32 || Array.from(cachedImages.values()).reduce((sum, value) => sum + value.length, 0) > 8 * 1024 * 1024) {
    cachedImages.delete(cachedImages.keys().next().value);
  }
  imageStyles.textContent = Array.from(cachedImages, ([src, png]) =>
    '#editor img[src="' + CSS.escape(src) + '"]{content:url("' + png + '")}').join('\\n');
};
for (const [source, data] of Object.entries(${jsonEncode(cachedImages).replaceAll('<', r'\u003c')})) window.cacheImage(source, data);
editor.innerHTML = original;
let changed = false;
let savedRange = null;
document.addEventListener('selectionchange', () => {
  const selection = window.getSelection();
  if (selection.rangeCount && editor.contains(selection.anchorNode) && editor.contains(selection.focusNode)) {
    savedRange = selection.getRangeAt(0).cloneRange();
  }
});
function restoreSelection() {
  editor.focus();
  if (savedRange && editor.contains(savedRange.commonAncestorContainer)) {
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(savedRange);
  }
}
function publish() { changed = true; Changes.postMessage(editor.innerHTML); }
editor.addEventListener('input', publish);
editor.addEventListener('paste', event => {
  event.preventDefault();
  document.execCommand('insertText', false, event.clipboardData.getData('text/plain'));
});
editor.addEventListener('drop', event => event.preventDefault());
document.addEventListener('click', event => {
  if (event.target.closest('a')) event.preventDefault();
});
window.readContent = () => changed ? editor.innerHTML : original;
window.format = (command, value) => {
  const allowed = ['bold','italic','underline','insertUnorderedList','insertOrderedList','formatBlock','undo','redo','unlink','strikeThrough','foreColor','hiliteColor','fontSize','justifyLeft','justifyCenter','justifyRight','justifyFull','removeFormat'];
  if (!allowed.includes(command)) return;
  restoreSelection();
  document.execCommand('styleWithCSS', false, ['foreColor','hiliteColor','justifyLeft','justifyCenter','justifyRight','justifyFull'].includes(command));
  document.execCommand(command, false, value);
  publish();
};
window.insertImage = reference => {
  if (!/^\\/api2\\/file\\/getImage\\?fileId=[0-9a-fA-F]{24}\$/.test(reference)) return;
  restoreSelection();
  const selection = window.getSelection();
  if (!selection.rangeCount || !editor.contains(selection.anchorNode)) {
    const range = document.createRange();
    range.selectNodeContents(editor);
    range.collapse(false);
    selection.removeAllRanges(); selection.addRange(range);
  } else selection.collapseToEnd();
  const image = document.createElement('img');
  image.setAttribute('src', reference); image.setAttribute('alt', '');
  document.execCommand('insertHTML', false, image.outerHTML);
  publish();
};
window.insertLink = value => {
  restoreSelection();
  const selection = window.getSelection();
  if (!selection.rangeCount || !editor.contains(selection.anchorNode)) return;
  if (selection.isCollapsed) {
    const link = document.createElement('a');
    link.href = value;
    link.textContent = value;
    document.execCommand('insertHTML', false, link.outerHTML);
  } else {
    document.execCommand('createLink', false, value);
  }
  publish();
};
window.insertTable = value => {
  restoreSelection();
  const selection = window.getSelection();
  if (!selection.rangeCount || !editor.contains(selection.anchorNode)) return;
  const anchor = selection.anchorNode.nodeType === Node.ELEMENT_NODE
    ? selection.anchorNode : selection.anchorNode.parentElement;
  if (anchor.closest('table')) {
    EditorError.postMessage(${jsonEncode(strings.text('tableCursorOutside')).replaceAll('<', r'\u003c')});
    return;
  }
  document.execCommand('insertHTML', false, value);
  publish();
};
let pendingTable = null;
window.selectedTable = id => {
  restoreSelection();
  const selection = window.getSelection();
  const node = selection.anchorNode;
  const element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
  const cell = element && element.closest('td,th');
  const table = cell && cell.closest('table');
  pendingTable = table && editor.contains(table) ? {id, table} : null;
  return pendingTable ? {id, html: table.outerHTML, row: Array.from(table.querySelectorAll('tr')).indexOf(cell.parentElement), column: cell.cellIndex} : {id};
};
window.replaceTable = (id, expected, replacement) => {
  const target = pendingTable;
  pendingTable = null;
  if (!target || target.id !== id || !editor.contains(target.table) || target.table.outerHTML !== expected) {
    EditorError.postMessage(${jsonEncode(strings.text('tableChanged')).replaceAll('<', r'\u003c')});
    return;
  }
  editor.focus();
  const range = document.createRange();
  range.selectNode(target.table);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  document.execCommand('insertHTML', false, replacement);
  publish();
};
</script></body></html>''';
}

class VisualHtmlEditor extends StatefulWidget {
  const VisualHtmlEditor({
    required this.source,
    this.strings = const AppStrings(Locale('zh')),
    required this.onChanged,
    required this.flush,
    this.loadCachedImage,
    this.insertImage,
    required this.saveError,
    super.key,
  });

  final String source;
  final CachedImageLoader? loadCachedImage;
  final Future<VisualImageInsertion?> Function()? insertImage;
  final AppStrings strings;
  final ValueChanged<String> onChanged;
  final Future<bool> Function() flush;
  final ValueListenable<String?> saveError;

  @override
  State<VisualHtmlEditor> createState() => _VisualHtmlEditorState();
}

class _VisualHtmlEditorState extends State<VisualHtmlEditor> {
  late final WebViewController _controller;
  bool _ready = false;
  bool _cacheStarted = false;
  bool _leaving = false;
  bool _allowPop = false;
  bool _dialogOpen = false;
  String? _error;
  Completer<String>? _snapshot;
  Completer<Map<String, dynamic>>? _tableSnapshot;
  int _tableRequest = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'TableSelection',
        onMessageReceived: (message) {
          final pending = _tableSnapshot;
          if (pending == null || pending.isCompleted) return;
          try {
            final value = jsonDecode(message.message) as Map<String, dynamic>;
            if (value['id'] == _tableRequest) pending.complete(value);
          } catch (error) {
            pending.completeError(error);
          }
        },
      )
      ..addJavaScriptChannel(
        'EditorError',
        onMessageReceived: (message) {
          if (mounted) setState(() => _error = message.message);
        },
      )
      ..addJavaScriptChannel(
        'Changes',
        onMessageReceived: (message) {
          if (mounted) _accept(message.message);
        },
      )
      ..addJavaScriptChannel(
        'Snapshot',
        onMessageReceived: (message) {
          final pending = _snapshot;
          if (pending != null && !pending.isCompleted) {
            pending.complete(message.message);
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              !_ready && request.url == 'about:blank'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) {
            if (mounted) {
              setState(() => _ready = true);
              if (!_cacheStarted) {
                _cacheStarted = true;
                unawaited(_loadCachedImages());
              }
            }
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame != false) {
              setState(
                () => _error = trNow(context, 'm0419', [error.description]),
              );
            }
          },
        ),
      );
    _load();
  }

  Future<void> _load() async {
    try {
      await _controller.loadHtmlString(
        visualEditorDocument(widget.source, strings: widget.strings),
      );
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0419', [error]));
    }
  }

  Future<void> _loadCachedImages() async {
    try {
      final images = await cachedVisualImages(
        widget.source,
        widget.loadCachedImage,
        shouldContinue: () => mounted,
      );
      for (final entry in images.entries) {
        if (!mounted) return;
        await _controller.runJavaScript(
          'window.cacheImage(${jsonEncode(entry.key)}, ${jsonEncode(entry.value)})',
        );
      }
    } on Object {
      // Cache preview failure does not affect source editing or persistence.
    }
  }

  bool _accept(String value) {
    if (!supportsVisualHtml(value)) {
      setState(() => _error = trNow(context, 'm0420'));
      return false;
    }
    widget.onChanged(value);
    setState(() => _error = null);
    return true;
  }

  Future<void> _close() async {
    if (_leaving || _dialogOpen) return;
    setState(() => _leaving = true);
    try {
      final saved = await persistVisualEdit(
        read: () async {
          if (!_ready) return null;
          final pending = Completer<String>();
          _snapshot = pending;
          final result = pending.future.timeout(const Duration(seconds: 5));
          unawaited(
            _controller
                .runJavaScript(
                  'editor.contentEditable = "false"; editor.blur(); Snapshot.postMessage(window.readContent())',
                )
                .catchError((Object error) {
                  if (!pending.isCompleted) pending.completeError(error);
                }),
          );
          return result;
        },
        accept: (value) => mounted && _accept(value),
        flush: widget.flush,
      );
      if (!mounted || !saved) return;
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0421', [error]));
    } finally {
      _snapshot = null;
      if (mounted && _ready && !_allowPop) {
        try {
          await _controller.runJavaScript('editor.contentEditable = "true"');
        } catch (error) {
          if (mounted) {
            setState(() => _error = trNow(context, 'm0422', [error]));
          }
        }
      }
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<void> _insertImage() async {
    if (_dialogOpen || !_ready || _leaving || widget.insertImage == null) {
      return;
    }
    setState(() => _dialogOpen = true);
    try {
      final pending = Completer<String>();
      _snapshot = pending;
      final read = pending.future.timeout(const Duration(seconds: 5));
      unawaited(
        _controller
            .runJavaScript(
              'editor.contentEditable = "false"; editor.blur(); Snapshot.postMessage(window.readContent())',
            )
            .catchError((Object error) {
              if (!pending.isCompleted) pending.completeError(error);
            }),
      );
      final source = await read;
      if (!mounted || !_accept(source) || !await widget.flush() || !mounted) {
        return;
      }
      final image = await widget.insertImage!();
      if (!mounted || image == null) return;
      if (!RegExp(r'^/api2/file/getImage\?fileId=[0-9a-fA-F]{24}$')
          .hasMatch(image.reference)) {
        throw const FormatException('invalidImageReference');
      }
      final data = await visualImageData(image.png);
      if (!mounted) return;
      if (data != null) {
        await _controller.runJavaScript(
          'window.cacheImage(${jsonEncode(image.reference)}, ${jsonEncode(data)})',
        );
      }
      await _controller.runJavaScript(
        'editor.contentEditable = "true"; window.insertImage(${jsonEncode(image.reference)})',
      );
      final inserted = Completer<String>();
      _snapshot = inserted;
      final result = inserted.future.timeout(const Duration(seconds: 5));
      unawaited(
        _controller
            .runJavaScript('Snapshot.postMessage(window.readContent())')
            .catchError((Object error) {
              if (!inserted.isCompleted) inserted.completeError(error);
            }),
      );
      final content = await result;
      if (mounted && _accept(content)) await widget.flush();
    } on Object catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0174', [error]));
    } finally {
      _snapshot = null;
      if (mounted) {
        try {
          await _controller.runJavaScript('editor.contentEditable = "true"');
        } on Object catch (error) {
          if (mounted) {
            setState(() => _error = trNow(context, 'm0422', [error]));
          }
        }
        if (mounted) setState(() => _dialogOpen = false);
      }
    }
  }

  Future<void> _insertLink() async {
    if (_dialogOpen || !_ready || _leaving) return;
    setState(() => _dialogOpen = true);
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => const EditorLinkDialog(),
      );
      if (!mounted || value == null) return;
      if (!isSafeEditorLink(value)) return;
      await _controller.runJavaScript(
        'window.insertLink(${jsonEncode(value)})',
      );
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0423', [error]));
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Future<void> _insertTable() async {
    if (_dialogOpen || !_ready || _leaving) return;
    setState(() => _dialogOpen = true);
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => const EditorTableDialog(),
      );
      if (!mounted || value == null) return;
      if (!supportsVisualHtml(value)) return;
      await _controller.runJavaScript(
        'window.insertTable(${jsonEncode(value)})',
      );
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0424', [error]));
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Widget _button(
    String label,
    IconData icon,
    String command, [
    String? value,
  ]) => IconButton(
    tooltip: label,
    icon: Icon(icon),
    onPressed: !_ready || _leaving || _dialogOpen
        ? null
        : () async {
            try {
              await _controller.runJavaScript(
                'window.format(${jsonEncode(command)}, ${jsonEncode(value)})',
              );
            } catch (error) {
              if (mounted) {
                setState(() => _error = trNow(context, 'm0425', [error]));
              }
            }
          },
  );

  Widget _styleMenu(
    String label,
    IconData icon,
    String command,
    Map<String, String> values,
  ) => PopupMenuButton<String>(
    tooltip: label,
    icon: Icon(icon),
    enabled: _ready && !_leaving && !_dialogOpen,
    itemBuilder: (_) => [
      for (final entry in values.entries)
        PopupMenuItem(value: entry.value, child: Text(entry.key)),
    ],
    onSelected: (value) async {
      try {
        await _controller.runJavaScript(
          'window.format(${jsonEncode(command)}, ${jsonEncode(value)})',
        );
      } catch (error) {
        if (mounted) setState(() => _error = trNow(context, 'm0425', [error]));
      }
    },
  );

  Future<void> _changeTable(TableOperation operation) async {
    if (!_ready || _leaving || _dialogOpen) return;
    setState(() => _dialogOpen = true);
    try {
      final pending = Completer<Map<String, dynamic>>();
      _tableSnapshot = pending;
      final id = ++_tableRequest;
      // Install timeout before dispatching, including native dispatch failures.
      final response = pending.future.timeout(const Duration(seconds: 5));
      unawaited(
        _controller
            .runJavaScript(
              'TableSelection.postMessage(JSON.stringify(window.selectedTable($id)))',
            )
            .catchError((Object error) {
              if (!pending.isCompleted) pending.completeError(error);
            }),
      );
      final snapshot = await response;
      if (!mounted) return;
      if (snapshot['html'] == null) {
        throw FormatException(trNow(context, 'm0426'));
      }
      final original = snapshot['html'] as String;
      final replacement = changeEditorTable(
        original,
        snapshot['row'] as int,
        snapshot['column'] as int,
        operation,
      );
      if (operation == TableOperation.removeRow ||
          operation == TableOperation.removeColumn) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              operation == TableOperation.removeRow
                  ? trNow(context, 'm0427')
                  : trNow(context, 'm0428'),
            ),
            content: Text(trNow(context, 'm0429')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(trNow(context, 'm0026')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(trNow(context, 'm0430')),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      }
      await _controller.runJavaScript(
        'window.replaceTable($id, ${jsonEncode(original)}, ${jsonEncode(replacement)})',
      );
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0431', [error]));
    } finally {
      _tableSnapshot = null;
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'm0179')),
        actions: [
          IconButton(
            tooltip: tr(context, 'm0432'),
            onPressed: _leaving ? null : _close,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: Column(
        children: [
          EditorSaveBanner(error: widget.saveError, retry: widget.flush),
          if (_error != null)
            MaterialBanner(
              content: Text(trMessage(context, _error!)),
              actions: [
                TextButton(
                  onPressed: _close,
                  child: Text(tr(context, 'm0006')),
                ),
              ],
            ),
          if (!_ready) const LinearProgressIndicator(),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (widget.insertImage != null)
                  IconButton(
                    tooltip: tr(context, 'visualInsertImage'),
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: _ready && !_leaving && !_dialogOpen
                        ? _insertImage
                        : null,
                  ),
                _button(tr(context, 'm0169'), Icons.undo, 'undo'),
                _button(tr(context, 'm0170'), Icons.redo, 'redo'),
                _button(tr(context, 'm0190'), Icons.format_bold, 'bold'),
                _button(tr(context, 'm0191'), Icons.format_italic, 'italic'),
                _button(
                  tr(context, 'm0433'),
                  Icons.format_underlined,
                  'underline',
                ),
                _button(
                  tr(context, 'm0197'),
                  Icons.format_strikethrough,
                  'strikeThrough',
                ),
                _styleMenu(
                  tr(context, 'm0434'),
                  Icons.format_color_text,
                  'foreColor',
                  {
                    tr(context, 'm0435'): '#000000',
                    tr(context, 'm0436'): '#d32f2f',
                    tr(context, 'm0437'): '#e65100',
                    tr(context, 'm0438'): '#2e7d32',
                    tr(context, 'm0439'): '#1565c0',
                    tr(context, 'm0440'): '#7b1fa2',
                  },
                ),
                _styleMenu(
                  tr(context, 'm0441'),
                  Icons.format_color_fill,
                  'hiliteColor',
                  {
                    tr(context, 'm0442'): 'transparent',
                    tr(context, 'm0443'): '#fff59d',
                    tr(context, 'm0438'): '#c8e6c9',
                    tr(context, 'm0439'): '#bbdefb',
                    tr(context, 'm0444'): '#f8bbd0',
                  },
                ),
                _styleMenu(
                  tr(context, 'm0445'),
                  Icons.format_size,
                  'fontSize',
                  {
                    tr(context, 'm0446'): '2',
                    tr(context, 'm0447'): '3',
                    tr(context, 'm0448'): '4',
                    tr(context, 'm0449'): '5',
                    tr(context, 'm0450'): '6',
                  },
                ),
                _button(
                  tr(context, 'm0451'),
                  Icons.format_align_left,
                  'justifyLeft',
                ),
                _button(
                  tr(context, 'm0452'),
                  Icons.format_align_center,
                  'justifyCenter',
                ),
                _button(
                  tr(context, 'm0453'),
                  Icons.format_align_right,
                  'justifyRight',
                ),
                _button(
                  tr(context, 'm0454'),
                  Icons.format_align_justify,
                  'justifyFull',
                ),
                _button(
                  tr(context, 'm0455'),
                  Icons.format_clear,
                  'removeFormat',
                ),
                _styleMenu(tr(context, 'm0193'), Icons.title, 'formatBlock', {
                  tr(context, 'm0456'): 'p',
                  for (var level = 1; level <= 6; level++)
                    tr(context, 'headingLevel', [level]): 'h$level',
                }),
                _button(tr(context, 'm0456'), Icons.notes, 'formatBlock', 'p'),
                _button(
                  tr(context, 'm0196'),
                  Icons.format_quote,
                  'formatBlock',
                  'blockquote',
                ),
                IconButton(
                  tooltip: tr(context, 'm0111'),
                  icon: const Icon(Icons.link),
                  onPressed: !_ready || _leaving || _dialogOpen
                      ? null
                      : _insertLink,
                ),
                _button(tr(context, 'm0457'), Icons.link_off, 'unlink'),
                PopupMenuButton<TableOperation>(
                  tooltip: tr(context, 'm0458'),
                  enabled: _ready && !_leaving && !_dialogOpen,
                  icon: const Icon(Icons.table_rows_outlined),
                  onSelected: _changeTable,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: TableOperation.mergeRight,
                      child: Text(tr(context, 'm0459')),
                    ),
                    PopupMenuItem(
                      value: TableOperation.mergeDown,
                      child: Text(tr(context, 'm0460')),
                    ),
                    PopupMenuItem(
                      value: TableOperation.splitCell,
                      child: Text(tr(context, 'm0461')),
                    ),
                    PopupMenuItem(
                      value: TableOperation.addRow,
                      child: Text(tr(context, 'm0462')),
                    ),
                    PopupMenuItem(
                      value: TableOperation.addColumn,
                      child: Text(tr(context, 'm0463')),
                    ),
                    PopupMenuItem(
                      value: TableOperation.removeRow,
                      child: Text(tr(context, 'm0464')),
                    ),
                    PopupMenuItem(
                      value: TableOperation.removeColumn,
                      child: Text(tr(context, 'm0465')),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: tr(context, 'm0119'),
                  icon: const Icon(Icons.table_chart_outlined),
                  onPressed: !_ready || _leaving || _dialogOpen
                      ? null
                      : _insertTable,
                ),
                _button(
                  tr(context, 'm0194'),
                  Icons.format_list_bulleted,
                  'insertUnorderedList',
                ),
                _button(
                  tr(context, 'm0195'),
                  Icons.format_list_numbered,
                  'insertOrderedList',
                ),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    ),
  );
}
