import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../repositories/auth_repository.dart';
import '../domain/models/tag_choices.dart';
import 'create_tag_dialog.dart';

class TagsPage extends StatefulWidget {
  const TagsPage({
    required this.repository,
    required this.accountId,
    this.session,
    super.key,
  });

  final AuthRepository repository;
  final String accountId;
  final StoredSession? session;

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  late Future<Map<String, int>> _tags;
  final _filter = TextEditingController();
  bool _includeUnused = false;
  String? _changing;

  Future<Map<String, int>> _loadTags() => _includeUnused
      ? widget.repository.availableTags(widget.accountId)
      : widget.repository.tagCounts(widget.accountId);

  Future<void> _createTag() async {
    final session = widget.session;
    if (session == null || session.account.cacheKey != widget.accountId) return;
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CreateTagDialog(
        onCreate: (name) => widget.repository.createTag(session, name),
      ),
    );
    if (created == true && mounted) {
      setState(() {
        _includeUnused = true;
        _filter.clear();
        _tags = _loadTags();
      });
    }
  }

  Future<void> _deleteTag(String name) async {
    final session = widget.session;
    if (session == null ||
        session.account.cacheKey != widget.accountId ||
        _changing != null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, 'm0667')),
        content: Text(trNow(context, 'm0668', [name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(trNow(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(trNow(context, 'm0667')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _changing = name);
    try {
      await widget.repository.deleteTag(session, name);
      if (mounted) setState(() => _tags = _loadTags());
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0669', [error]))),
        );
      }
    } finally {
      if (mounted) setState(() => _changing = null);
    }
  }

  Future<void> _renameTag(String name) async {
    final session = widget.session;
    if (session == null ||
        session.account.cacheKey != widget.accountId ||
        _changing != null) {
      return;
    }
    var editedName = name;
    final replacement = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trNow(context, 'm0670')),
        content: TextFormField(
          initialValue: name,
          onChanged: (value) => editedName = value,
          autofocus: true,
          maxLength: 200,
          decoration: InputDecoration(labelText: trNow(context, 'm0103')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(trNow(context, 'm0026')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, editedName),
            child: Text(trNow(context, 'm0025')),
          ),
        ],
      ),
    );
    if (replacement == null || !mounted) return;
    setState(() => _changing = name);
    try {
      await widget.repository.renameTag(session, name, replacement);
      if (mounted) setState(() => _tags = _loadTags());
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trNow(context, 'm0671', [error]))),
        );
      }
    } finally {
      if (mounted) setState(() => _changing = null);
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tags = _loadTags();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'm0410')),
      actions: [
        if (widget.session != null)
          IconButton(
            onPressed: _createTag,
            tooltip: tr(context, 'm0101'),
            icon: const Icon(Icons.add),
          ),
      ],
    ),
    body: FutureBuilder<Map<String, int>>(
      future: _tags,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                _tags = _loadTags();
              }),
              child: Text(tr(context, 'm0411')),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final filtering = _filter.text.trim().isNotEmpty;
        final entries = tagChoices(
          snapshot.data!,
          query: _filter.text,
          limit: filtering || _includeUnused ? null : 10,
          includeUnused: _includeUnused,
        );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _filter,
                decoration: InputDecoration(
                  labelText: tr(context, 'm0412'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _filter.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: tr(context, 'm0413'),
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(_filter.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            CheckboxListTile(
              title: Text(tr(context, 'm0414')),
              value: _includeUnused,
              onChanged: (value) => setState(() {
                _includeUnused = value ?? false;
                _tags = _loadTags();
              }),
            ),
            if (!filtering && !_includeUnused && snapshot.data!.length > 10)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(tr(context, 'm0415')),
              ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        filtering
                            ? tr(context, 'm0416')
                            : _includeUnused
                            ? tr(context, 'm0417')
                            : tr(context, 'm0418'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final tag = entries[index];
                        return ListTile(
                          leading: const Icon(Icons.label_outline),
                          title: Text(
                            tag.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _changing == tag.key
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(),
                                )
                              : widget.session == null
                              ? Text('${tag.value}')
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('${tag.value}'),
                                    PopupMenuButton<String>(
                                      enabled: _changing == null,
                                      onSelected: (action) => action == 'rename'
                                          ? _renameTag(tag.key)
                                          : _deleteTag(tag.key),
                                      itemBuilder: (context) => [
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text(tr(context, 'm0670')),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text(tr(context, 'm0667')),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                          onTap: () => Navigator.of(context).pop(tag.key),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}
