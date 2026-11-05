import 'package:flutter/material.dart';

import '../domain/models/note.dart';
import '../repositories/auth_repository.dart';
import '../l10n/app_strings.dart';

class NoteSharingDialog extends StatefulWidget {
  const NoteSharingDialog({
    super.key,
    required this.repository,
    required this.session,
    required this.note,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Note note;
  @override
  State<NoteSharingDialog> createState() => _NoteSharingDialogState();
}

class _NoteSharingDialogState extends State<NoteSharingDialog> {
  final _email = TextEditingController();
  final _recipientFocus = FocusNode();
  List<String> _suggestions = [];
  List<Map<String, Object?>> _members = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run([Future<void> Function()? action]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action?.call();
      final members = await widget.repository.shareMembers(
        widget.session,
        widget.note,
      );
      if (mounted) setState(() => _members = members);
      final navigation = await widget.repository.sharingNavigation(
        widget.session,
        refresh: true,
      );
      if (mounted) {
        setState(
          () => _suggestions = {
            ...navigation.suggestions.map((u) => u.username),
            ...navigation.recipients.map((u) => u.username),
          }.where((s) => s.isNotEmpty).toList()..sort(),
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = AppStrings.snapshot(context).errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _recipientFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, 'manageSharing')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RawAutocomplete<String>(
                textEditingController: _email,
                focusNode: _recipientFocus,
                optionsBuilder: (value) => _busy
                    ? const Iterable<String>.empty()
                    : _suggestions
                          .where(
                            (name) => name.toLowerCase().contains(
                              value.text.trim().toLowerCase(),
                            ),
                          )
                          .take(20),
                fieldViewBuilder:
                    (context, controller, focusNode, onSubmitted) => TextField(
                      controller: controller,
                      focusNode: focusNode,
                      enabled: !_busy,
                      keyboardType: TextInputType.text,
                      decoration: InputDecoration(
                        labelText: tr(context, 'shareRecipientIdentity'),
                      ),
                      onSubmitted: (_) => onSubmitted(),
                    ),
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: 200,
                        maxWidth: MediaQuery.sizeOf(context).width - 100,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (context, index) => ListTile(
                          dense: true,
                          selected:
                              AutocompleteHighlightedOption.of(context) ==
                              index,
                          title: Text(options.elementAt(index)),
                          onTap: () => onSelected(options.elementAt(index)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        if (_email.text.trim().isEmpty) {
                          setState(
                            () => _error = trNow(
                              context,
                              'shareRecipientRequired',
                            ),
                          );
                          return;
                        }
                        await widget.repository.shareNote(
                          widget.session,
                          widget.note,
                          _email.text,
                        );
                        if (mounted) _email.clear();
                      }),
                child: Text(tr(context, 'shareReadOnly')),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  trMessage(context, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              for (final member in _members)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(member['Email']?.toString() ?? ''),
                  subtitle: Text(
                    tr(
                      context,
                      member['NotebookHasShared'] == true
                          ? 'inheritedShare'
                          : 'shareReadOnly',
                    ),
                  ),
                  trailing: member['NotebookHasShared'] == true
                      ? null
                      : IconButton(
                          tooltip: tr(context, 'revokeShare'),
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () => widget.repository.revokeNoteShare(
                                    widget.session,
                                    widget.note,
                                    member['ToUserId'] as String,
                                  ),
                                ),
                          icon: const Icon(Icons.link_off),
                        ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _run(),
          child: Text(tr(context, 'm0006')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(tr(context, 'm0010')),
        ),
      ],
    ),
  );
}
