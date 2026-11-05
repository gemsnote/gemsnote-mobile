import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models/note_search_result.dart';
import '../repositories/auth_repository.dart';

class NoteSearchPage extends StatefulWidget {
  const NoteSearchPage({
    required this.repository,
    required this.session,
    super.key,
  });

  final AuthRepository repository;
  final StoredSession session;

  @override
  State<NoteSearchPage> createState() => _NoteSearchPageState();
}

class _NoteSearchPageState extends State<NoteSearchPage> {
  final _query = TextEditingController();
  List<NoteSearchResult> _results = const [];
  var _generation = 0;
  static const _pageSize = 50;
  var _limit = _pageSize;
  var _retryLimit = _pageSize;
  bool _busy = false;
  String? _openingId;
  String? _openError;
  bool _hasMore = false;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _queryChanged(String value) {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _results = [];
      _openingId = null;
      _openError = null;
      _limit = _pageSize;
      _hasMore = false;
      _error = null;
      _busy = value.trim().isNotEmpty;
    });
    if (_busy) {
      _debounce = Timer(
        const Duration(milliseconds: 250),
        () => _search(generation),
      );
    }
  }

  Future<void> _search(int generation, {int? limit}) async {
    final requested = limit ?? _limit;
    setState(() {
      _busy = true;
      _error = null;
      _retryLimit = requested;
    });
    try {
      // Re-read the growing prefix rather than append offsets: concurrent
      // syncs or edits must not duplicate/skip rows across page boundaries.
      final results = await widget.repository.searchNoteSummaries(
        widget.session.account.cacheKey,
        _query.text.trim(),
        limit: requested + 1,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _limit = requested;
        _hasMore = results.length > requested;
        _results = results.take(requested).toList();
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = trNow(context, 'm0295', [error]));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _open(NoteSearchResult result) async {
    if (_openingId != null) return;
    final generation = _generation;
    setState(() {
      _openingId = result.noteId;
      _openError = null;
    });
    try {
      final note = await widget.repository.searchableNote(
        widget.session.account.cacheKey,
        result.noteId,
      );
      if (!mounted || generation != _generation) return;
      if (note == null) {
        setState(() => _openError = trNow(context, 'm0296'));
      } else {
        Navigator.pop(context, note);
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _openError = trNow(context, 'm0297', [error]));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _openingId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        controller: _query,
        autofocus: true,
        onChanged: _queryChanged,
        decoration: InputDecoration(
          hintText: tr(context, 'm0298'),
          border: InputBorder.none,
        ),
      ),
    ),
    body: Column(
      children: [
        if (_busy || _openingId != null) const LinearProgressIndicator(),
        if (_openError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _openError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_error != null)
          ListTile(
            title: Text(
              trMessage(context, _error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () => _search(_generation, limit: _retryLimit),
              child: Text(tr(context, 'm0006')),
            ),
          ),
        if (_results.isNotEmpty)
          Text(
            tr(context, 'm0300', [
              _results.length,
              _hasMore ? tr(context, 'm0299') : '',
            ]),
          ),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(
                    _query.text.trim().isEmpty
                        ? tr(context, 'm0301')
                        : _busy
                        ? tr(context, 'm0302')
                        : _error != null
                        ? tr(context, 'm0303')
                        : tr(context, 'm0304'),
                  ),
                )
              : ListView.separated(
                  itemCount: _results.length + (_hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index == _results.length) {
                      return TextButton(
                        onPressed: _busy
                            ? null
                            : () => _search(
                                _generation,
                                limit: _limit + _pageSize,
                              ),
                        child: Text(tr(context, 'm0305')),
                      );
                    }
                    final note = _results[index];
                    return ListTile(
                      leading: Icon(
                        note.isMarkdown ? Icons.code : Icons.article_outlined,
                      ),
                      title: Text(
                        note.title.isEmpty ? tr(context, 'm0275') : note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        "${note.isMarkdown ? 'MD' : 'RT'} ${note.updatedTime}",
                        maxLines: 1,
                      ),
                      onTap: _openingId == null ? () => _open(note) : null,
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
