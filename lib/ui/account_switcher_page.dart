import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../domain/models/account.dart';
import '../repositories/auth_repository.dart';
import 'login_page.dart';

class AccountSwitcherPage extends StatefulWidget {
  const AccountSwitcherPage({
    super.key,
    required this.repository,
    this.current,
    this.beforeLoad,
  });
  final AuthRepository repository;
  final StoredSession? current;
  final Future<void> Function()? beforeLoad;

  @override
  State<AccountSwitcherPage> createState() => _AccountSwitcherPageState();
}

class _AccountSwitcherPageState extends State<AccountSwitcherPage> {
  List<Account> _accounts = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.beforeLoad?.call();
      final accounts = await widget.repository.savedAccounts();
      if (mounted) setState(() => _accounts = accounts);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0048'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(Account account) async {
    if (_busy || _loading) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.repository.switchAccount(account.cacheKey);
      if (mounted) Navigator.pop(context, session);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0049'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    if (_busy || _loading) return;
    setState(() => _busy = true);
    try {
      final session = await Navigator.push<StoredSession>(
        context,
        MaterialPageRoute(
          builder: (loginContext) => LoginPage(
            repository: widget.repository,
            allowBack: true,
            onSignedIn: (session) => Navigator.pop(loginContext, session),
          ),
        ),
      );
      if (mounted && session != null) Navigator.pop(context, session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_loading,
    child: Scaffold(
      appBar: AppBar(title: Text(tr(context, 'm0050'))),
      body: ListView(
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(tr(context, 'm0051')),
          ),
          if (_loading || _busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                trMessage(context, _error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_error != null && !_busy && !_loading)
            TextButton(onPressed: _load, child: Text(tr(context, 'm0052'))),
          for (final account in _accounts)
            ListTile(
              title: Text(
                account.username.isEmpty ? account.userId : account.username,
              ),
              subtitle: Text(
                '${account.server}\n${account.email.isEmpty ? account.userId : account.email}',
              ),
              isThreeLine: true,
              trailing: account.cacheKey == widget.current?.account.cacheKey
                  ? Text(tr(context, 'm0053'))
                  : null,
              enabled: !_busy && !_loading,
              onTap: account.cacheKey == widget.current?.account.cacheKey
                  ? () => Navigator.pop(context)
                  : () => _select(account),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _busy || _loading ? null : _add,
              icon: const Icon(Icons.person_add_outlined),
              label: Text(tr(context, 'm0054')),
            ),
          ),
        ],
      ),
    ),
  );
}
