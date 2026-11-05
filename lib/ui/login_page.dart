import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../l10n/language_controller.dart';
import 'language_dialog.dart';

import '../repositories/auth_repository.dart';
import 'password_reset_page.dart';
import 'account_switcher_page.dart';
import 'cached_login_dialog.dart';
import 'sync_progress_dialog.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    required this.repository,
    required this.onSignedIn,
    this.allowBack = false,
    this.onSessionRestored,
    super.key,
  });

  final bool allowBack;
  final AuthRepository repository;
  final ValueChanged<StoredSession> onSignedIn;
  final ValueChanged<StoredSession>? onSessionRestored;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _identity = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _identity.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var authenticated = false;
    try {
      final pending = await widget.repository.beginLogin(
        serverAddress: _server.text,
        identity: _identity.text,
        password: _password.text,
      );
      authenticated = true;
      if (!mounted) return;
      final reset = pending.hasCache
          ? await chooseCachedLoginReset(context)
          : false;
      if (!mounted) return;
      late StoredSession session;
      if (!pending.hasCache || reset) {
        await showSyncProgress(
          context,
          cancel: widget.repository.cancelSync,
          synchronize: (progress) async {
            session = await widget.repository.completeLogin(
              pending,
              resetCache: reset,
              onProgress: progress,
            );
          },
        );
      } else {
        session = await widget.repository.completeLogin(
          pending,
          resetCache: false,
        );
      }
      if (mounted) widget.onSignedIn(session);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = authenticated
              ? trNow(context, 'loginSyncFailed', [_message(error)])
              : _message(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseSavedAccount() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = await Navigator.push<StoredSession>(
        context,
        MaterialPageRoute(
          builder: (_) => AccountSwitcherPage(repository: widget.repository),
        ),
      );
      if (mounted && session != null) {
        (widget.onSessionRestored ?? widget.onSignedIn)(session);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: widget.allowBack || LanguageScope.maybeOf(context) != null
            ? AppBar(
                title: widget.allowBack ? Text(tr(context, 'm0054')) : null,
                actions: [
                  if (LanguageScope.maybeOf(context) != null)
                    IconButton(
                      tooltip: tr(context, 'languageTitle'),
                      icon: const Icon(Icons.language),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const LanguageDialog(),
                      ),
                    ),
                ],
              )
            : null,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Image.asset(
                            'assets/images/gemsnote_s.png',
                            height: 72,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tr(context, 'm0141'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            tr(context, 'm0003'),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 28),
                          TextFormField(
                            readOnly: _busy,
                            controller: _server,
                            keyboardType: TextInputType.url,
                            autofillHints: const [AutofillHints.url],
                            decoration: InputDecoration(
                              labelText: tr(context, 'm0040'),
                              hintText: 'https://notes.example.com',
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? tr(context, 'm0142')
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            readOnly: _busy,
                            controller: _identity,
                            autofillHints: const [AutofillHints.username],
                            decoration: InputDecoration(
                              labelText: tr(context, 'm0143'),
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? tr(context, 'm0144')
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            readOnly: _busy,
                            controller: _password,
                            obscureText: true,
                            autofillHints: const [AutofillHints.password],
                            decoration: InputDecoration(
                              labelText: tr(context, 'm0145'),
                            ),
                            validator: (value) => value == null || value.isEmpty
                                ? tr(context, 'm0146')
                                : null,
                            onFieldSubmitted: (_) => _login(),
                          ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                trMessage(context, _error!),
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          if (_busy)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Column(
                                children: [
                                  const LinearProgressIndicator(),
                                  const SizedBox(height: 8),
                                  Text(tr(context, 'm0147')),
                                ],
                              ),
                            ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _busy ? null : _login,
                            child: Text(tr(context, 'm0148')),
                          ),
                          if (!widget.allowBack)
                            TextButton(
                              onPressed: _busy ? null : _chooseSavedAccount,
                              child: Text(tr(context, 'm0149')),
                            ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => PasswordResetPage(
                                          repository: widget.repository,
                                          serverAddress: _server.text,
                                          email: _identity.text.contains('@')
                                              ? _identity.text
                                              : '',
                                        ),
                                      ),
                                    );
                                  },
                            child: Text(tr(context, 'm0150')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _message(Object error) =>
      AppStrings.snapshot(context).errorMessage(error);
}
