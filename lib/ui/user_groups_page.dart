import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../domain/models/user_group.dart';
import '../l10n/app_strings.dart';
import '../repositories/auth_repository.dart';

String _groupError(BuildContext context, Object error) =>
    error is ApiException && error.code == 'userNotExists'
    ? trNow(context, 'groupUserMissing')
    : AppStrings.snapshot(context).errorMessage(error);

class UserGroupsPage extends StatefulWidget {
  const UserGroupsPage({
    super.key,
    required this.repository,
    required this.session,
  });
  final AuthRepository repository;
  final StoredSession session;
  @override
  State<UserGroupsPage> createState() => _UserGroupsPageState();
}

class _UserGroupsPageState extends State<UserGroupsPage> {
  List<UserGroup> _groups = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final groups = await widget.repository.groups(widget.session);
      if (mounted) setState(() => _groups = groups);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _groupError(context, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit({UserGroup? group, bool member = false}) async {
    if (_busy) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _GroupInputDialog(
        title: member
            ? 'groupAddMember'
            : group == null
            ? 'groupCreate'
            : 'groupRename',
        member: member,
        value: member ? '' : group?.title ?? '',
        save: (value) => member
            ? widget.repository.addGroupMember(
                widget.session,
                group!.groupId,
                value,
              )
            : group == null
            ? widget.repository.createGroup(widget.session, value)
            : widget.repository.renameGroup(
                widget.session,
                group.groupId,
                value,
              ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _remove(UserGroup group, [GroupMember? member]) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          tr(context, member == null ? 'groupDelete' : 'groupRemoveMember'),
        ),
        content: Text(
          tr(
            context,
            member == null ? 'groupDeleteConfirm' : 'groupRemoveConfirm',
            [member?.label ?? group.title],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'groupConfirm')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'm0026')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (member == null) {
        await widget.repository.deleteGroup(widget.session, group.groupId);
      } else {
        await widget.repository.removeGroupMember(
          widget.session,
          group.groupId,
          member.userId,
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = _groupError(context, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'userGroups')),
      actions: [
        IconButton(
          tooltip: tr(context, 'm0035'),
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(tr(context, 'groupsDescription')),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : () => _edit(),
          icon: const Icon(Icons.group_add),
          label: Text(tr(context, 'groupCreate')),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (!_busy && _error == null && _groups.isEmpty)
          Text(tr(context, 'groupsEmpty')),
        for (final group in _groups)
          Card(
            child: ExpansionTile(
              key: PageStorageKey(group.groupId),
              title: Text(group.title),
              subtitle: Text(
                tr(context, 'groupMemberCount', [group.members.length]),
              ),
              childrenPadding: const EdgeInsets.all(12),
              children: [
                if (group.ownerId == widget.session.account.userId)
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _edit(group: group, member: true),
                        icon: const Icon(Icons.person_add),
                        label: Text(tr(context, 'groupAddMember')),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _edit(group: group),
                        child: Text(tr(context, 'groupRename')),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _remove(group),
                        child: Text(tr(context, 'groupDelete')),
                      ),
                    ],
                  )
                else
                  Text(tr(context, 'groupReadOnly')),
                if (group.members.isEmpty)
                  Text(tr(context, 'groupMembersEmpty')),
                for (final member in group.members)
                  ListTile(
                    title: Text(member.label),
                    subtitle: member.email.isEmpty ? null : Text(member.email),
                    trailing: group.ownerId != widget.session.account.userId
                        ? null
                        : IconButton(
                            tooltip: tr(context, 'groupRemoveMember'),
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: _busy
                                ? null
                                : () => _remove(group, member),
                          ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _GroupInputDialog extends StatefulWidget {
  const _GroupInputDialog({
    required this.title,
    required this.member,
    required this.value,
    required this.save,
  });
  final String title, value;
  final bool member;
  final Future<void> Function(String) save;
  @override
  State<_GroupInputDialog> createState() => _GroupInputDialogState();
}

class _GroupInputDialogState extends State<_GroupInputDialog> {
  late final _input = TextEditingController(text: widget.value);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_input.value.composing.isCollapsed) return;
    final value = _input.text.trim();
    if (value.isEmpty) {
      setState(
        () => _error = trNow(
          context,
          widget.member ? 'shareRecipientRequired' : 'groupNameRequired',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(value);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _groupError(context, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(tr(context, widget.title)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _input,
              enabled: !_busy,
              autofocus: true,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: widget.member ? 254 : 100,
              decoration: InputDecoration(
                labelText: tr(
                  context,
                  widget.member ? 'shareRecipientIdentity' : 'groupName',
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(tr(context, widget.member ? 'groupAddMember' : 'm0025')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(tr(context, 'm0026')),
        ),
      ],
    ),
  );
}
