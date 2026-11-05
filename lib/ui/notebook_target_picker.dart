import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/notebook.dart';
import '../domain/models/notebook_tree.dart';

/// Uses the same repaired presentation tree as the workspace; never changes IDs.
class NotebookTargetPicker extends StatefulWidget {
  const NotebookTargetPicker({
    super.key,
    required this.notebooks,
    required this.onSelected,
    this.selected,
    this.allowRoot = false,
    this.enabled = true,
    this.canSelect,
  });
  final List<Notebook> notebooks;
  final ValueChanged<String> onSelected;
  final String? selected;
  final bool allowRoot;
  final bool enabled;
  final bool Function(String)? canSelect;
  @override
  State<NotebookTargetPicker> createState() => _NotebookTargetPickerState();
}

class _NotebookTargetPickerState extends State<NotebookTargetPicker> {
  final _expanded = <String>{};
  String _search = '';

  List<NotebookTreeRow> _rows() {
    final tree = NotebookTree(widget.notebooks);
    final key = _search.trim().toLowerCase();
    if (key.isEmpty) return tree.visibleRows(_expanded);
    final all = tree.visibleRows(
      widget.notebooks.map((n) => n.notebookId).toSet(),
    );
    final keep = <String>{};
    final ancestors = <NotebookTreeRow>[];
    for (final row in all) {
      while (ancestors.isNotEmpty && ancestors.last.depth >= row.depth) {
        ancestors.removeLast();
      }
      ancestors.add(row);
      if (row.notebook.title.toLowerCase().contains(key)) {
        keep.addAll(ancestors.map((a) => a.notebook.notebookId));
      }
    }
    return all.where((row) => keep.contains(row.notebook.notebookId)).toList();
  }

  Widget _choice(
    String id,
    String title, {
    int depth = 0,
    bool hasChildren = false,
  }) => Padding(
    padding: EdgeInsets.only(left: depth.clamp(0, 8) * 12.0),
    child: Row(
      children: [
        SizedBox(
          width: 36,
          child: hasChildren
              ? IconButton(
                  tooltip: _expanded.contains(id)
                      ? trNow(context, 'm0333', [title])
                      : trNow(context, 'm0334', [title]),
                  onPressed: widget.enabled && _search.trim().isEmpty
                      ? () => setState(() {
                          _expanded.contains(id)
                              ? _expanded.remove(id)
                              : _expanded.add(id);
                        })
                      : null,
                  icon: Icon(
                    _search.trim().isNotEmpty || _expanded.contains(id)
                        ? Icons.expand_more
                        : Icons.chevron_right,
                  ),
                )
              : const Icon(Icons.folder_outlined, size: 20),
        ),
        Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Tooltip(
              message: title,
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            selected: widget.selected == id,
            trailing: Icon(
              widget.selected == id
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            enabled: widget.enabled && (widget.canSelect?.call(id) ?? true),
            onTap: () => widget.onSelected(id),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return Column(
      children: [
        TextField(
          enabled: widget.enabled,
          decoration: InputDecoration(
            labelText: tr(context, 'm0335'),
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _search = value),
        ),
        Expanded(
          child: ListView(
            children: [
              if (widget.allowRoot) _choice('', tr(context, 'm0336')),
              for (final row in rows)
                _choice(
                  row.notebook.notebookId,
                  row.notebook.title,
                  depth: row.depth,
                  hasChildren: row.hasChildren,
                ),
              if (rows.isEmpty)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(tr(context, 'm0337')),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
