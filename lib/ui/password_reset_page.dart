import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../repositories/auth_repository.dart';

class PasswordResetPage extends StatefulWidget {
  const PasswordResetPage({
    super.key,
    required this.repository,
    this.serverAddress = '',
    this.email = '',
  });
  final AuthRepository repository;
  final String serverAddress;
  final String email;
  @override
  State<PasswordResetPage> createState() => _PasswordResetPageState();
}

class _PasswordResetPageState extends State<PasswordResetPage> {
  final _form = GlobalKey<FormState>();
  late final _server = TextEditingController(text: widget.serverAddress);
  late final _email = TextEditingController(text: widget.email);
  bool _busy = false;
  bool _sent = false;
  String? _error;
  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.requestPasswordReset(_server.text, _email.text);
      if (mounted) setState(() => _sent = true);
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0344', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr(context, 'm0150'))),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: _sent
          ? Text(tr(context, 'm0345'))
          : Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _server,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: tr(context, 'm0040'),
                    ),
                    validator: (value) {
                      try {
                        AuthRepository.normalizeServer(value ?? '');
                        return null;
                      } catch (_) {
                        return tr(context, 'm0346');
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: tr(context, 'm0347'),
                    ),
                    validator: (value) =>
                        RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                            .hasMatch(value?.trim() ?? '')
                        ? null
                        : tr(context, 'm0013'),
                  ),
                  const SizedBox(height: 16),
                  Text(tr(context, 'm0348')),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        trMessage(context, _error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  if (_busy) const LinearProgressIndicator(),
                  FilledButton(
                    onPressed: _busy ? null : _send,
                    child: Text(tr(context, 'm0349')),
                  ),
                ],
              ),
            ),
    ),
  );
}
