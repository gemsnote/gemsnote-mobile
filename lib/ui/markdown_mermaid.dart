import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/app_strings.dart';
import 'markdown_attributes.dart';

class MermaidFenceSyntax extends AttributeCodeFenceSyntax {
  const MermaidFenceSyntax();
  @override
  md.Node parse(md.BlockParser parser) {
    final node = super.parse(parser) as md.Element;
    final code = node.children!.single as md.Element;
    if (code.attributes['class']?.toLowerCase() != 'language-mermaid') {
      return node;
    }
    return md.Element.text('gemsnote-mermaid', code.textContent)
      ..attributes.addAll(node.attributes);
  }
}

bool canRenderMermaid(String source) =>
    source.trim().isNotEmpty &&
    source.length <= 20000 &&
    source.split('\n').length <= 500 &&
    !RegExp(r'%%\s*\{|^\s*---(?:\r?\n|$)').hasMatch(source);

typedef MermaidRender = Future<Uint8List> Function(String source);

/// Each document uses one isolated, local renderer. Only PNG results cross the
/// channel; no credentials, API client, navigation or native command bridge.
class MermaidScope extends StatefulWidget {
  const MermaidScope({required this.child, this.renderOverride, super.key});
  final Widget child;
  final MermaidRender? renderOverride;
  static MermaidRender? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MermaidProvider>()?.render;
  @override
  State<MermaidScope> createState() => _MermaidScopeState();
}

class _MermaidScopeState extends State<MermaidScope> {
  WebViewController? _controller;
  final _ready = Completer<void>();
  final _cache = <String, Future<Uint8List>>{};
  final _pending = <int, Completer<Uint8List>>{};
  Future<void> _queue = Future.value();
  Future<void>? _starting;
  int _sequence = 0;
  int _requested = 0;
  bool _disposed = false;

  Future<void> _start() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      'MermaidResult',
      onMessageReceived: (message) {
        if (_disposed || message.message.length > 12000000) return;
        try {
          final data = jsonDecode(message.message) as Map<String, dynamic>;
          if (data['channel'] != 'gemsnote-mermaid') return;
          if (data['ready'] == true) {
            if (!_ready.isCompleted) _ready.complete();
            return;
          }
          final task = _pending.remove(data['id']);
          if (task == null) return;
          final png = data['png'];
          if (png is String && png.startsWith('data:image/png;base64,')) {
            try {
              task.complete(base64Decode(png.substring(22)));
            } on Object {
              task.completeError(StateError('invalidImage'));
            }
          } else {
            task.completeError(StateError('renderFailed'));
          }
        } on Object {
          /* Ignore malformed messages from the rendering sandbox. */
        }
      },
    );
    var initialAssetNavigation = true;
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (initialAssetNavigation &&
              uri?.scheme == 'file' &&
              uri!.path.endsWith('/assets/mermaid/index.html') &&
              !uri.hasQuery &&
              !uri.hasFragment) {
            initialAssetNavigation = false;
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
      ),
    );
    if (_disposed) return;
    setState(() => _controller = controller);
    await controller.loadFlutterAsset('assets/mermaid/index.html');
    await _ready.future.timeout(const Duration(seconds: 20));
  }

  Future<Uint8List> _render(String source) {
    if (!canRenderMermaid(source)) return Future.error(StateError('limit'));
    if (!_cache.containsKey(source) && ++_requested > 32) {
      return Future.error(StateError('limit'));
    }
    return _cache.putIfAbsent(source, () {
      final result = Completer<Uint8List>();
      // Markdown builds all blocks together; start the platform view after build.
      _queue = _queue.then((_) async {
        try {
          if (_disposed) throw StateError('disposed');
          _starting ??= _start();
          await _starting;
          if (_disposed) throw StateError('disposed');
          final id = ++_sequence;
          final task = Completer<Uint8List>();
          _pending[id] = task;
          final response = task.future.timeout(const Duration(seconds: 30));
          try {
            final replies = await Future.wait<Object?>([
              response,
              _controller!.runJavaScript(
                'window.renderGemsnoteMermaid(${jsonEncode({'channel': 'gemsnote-mermaid', 'id': id, 'source': source, 'format': 'png'})});',
              ),
            ]);
            result.complete(replies.first as Uint8List);
          } finally {
            _pending.remove(id);
          }
        } on Object catch (error, stack) {
          result.completeError(error, stack);
        }
      });
      return result.future;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_ready.isCompleted) _ready.complete();
    for (final task in _pending.values) {
      task.completeError(StateError('disposed'));
    }
    _pending.clear();
    _cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MermaidProvider(
    render: widget.renderOverride ?? _render,
    child: Stack(
      children: [
        widget.child,
        if (_controller != null)
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0,
                  child: WebViewWidget(controller: _controller!),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _MermaidProvider extends InheritedWidget {
  const _MermaidProvider({required this.render, required super.child});
  final MermaidRender render;
  @override
  bool updateShouldNotify(_MermaidProvider oldWidget) =>
      render != oldWidget.render;
}

class MermaidElementBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => MermaidDiagram(source: element.textContent);
}

class MermaidDiagram extends StatefulWidget {
  const MermaidDiagram({required this.source, super.key});
  final String source;
  @override
  State<MermaidDiagram> createState() => _MermaidDiagramState();
}

class _MermaidDiagramState extends State<MermaidDiagram> {
  Future<Uint8List>? _image;
  MermaidRender? _renderer;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final render = MermaidScope.of(context);
    if (_image == null || render != _renderer) {
      _renderer = render;
      _image =
          render?.call(widget.source) ??
          Future.error(StateError('unavailable'));
    }
  }

  @override
  void didUpdateWidget(MermaidDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source) {
      _image = _renderer?.call(widget.source);
    }
  }

  void _enlarge(Uint8List bytes) => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: Text(tr(context, 'mermaidDiagram'))),
        body: InteractiveViewer(
          minScale: 0.25,
          maxScale: 6,
          child: Center(
            child: Image.memory(
              bytes,
              semanticLabel: tr(context, 'mermaidDiagram'),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _image,
    builder: (context, snapshot) => Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffd5ded9)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (snapshot.hasData)
              Semantics(
                button: true,
                label: tr(context, 'mermaidEnlarge'),
                child: InkWell(
                  onTap: () => _enlarge(snapshot.data!),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          Text(tr(context, 'mermaidFailed')),
                    ),
                  ),
                ),
              )
            else
              Text(
                tr(
                  context,
                  snapshot.hasError ? 'mermaidFailed' : 'mermaidLoading',
                ),
              ),
            ExpansionTile(
              key: ValueKey(snapshot.hasError),
              title: Text(tr(context, 'mermaidSource')),
              initiallyExpanded: snapshot.hasError,
              children: [
                SelectableText(widget.source),
                TextButton.icon(
                  icon: const Icon(Icons.copy),
                  label: Text(tr(context, 'mermaidCopy')),
                  onPressed: () async {
                    try {
                      await Clipboard.setData(
                        ClipboardData(text: widget.source),
                      );
                    } on Object {
                      /* Source remains selectable if clipboard is unavailable. */
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
