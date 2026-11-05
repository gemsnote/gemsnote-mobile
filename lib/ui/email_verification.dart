import 'dart:async';

import '../core/api/api_exception.dart';

import 'package:flutter/material.dart';

import '../domain/models/account.dart';
import '../repositories/auth_repository.dart';
import '../l10n/app_strings.dart';

class EmailVerification extends StatefulWidget {
  const EmailVerification({
    super.key,
    required this.repository,
    required this.session,
    required this.account,
  });
  final AuthRepository repository;
  final StoredSession session;
  final Account account;
  @override
  State<EmailVerification> createState() => _EmailVerificationState();
}

class _EmailVerificationState extends State<EmailVerification> {
  final _email = TextEditingController(), _password = TextEditingController();
  String? _task, _error;
  String _state = '', _pending = '';
  bool _sending = false, _checking = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _pending = widget.account.pendingEmail;
    _restore();
  }

  @override
  void didUpdateWidget(covariant EmailVerification old) {
    super.didUpdateWidget(old);
    if (old.account.pendingEmail != widget.account.pendingEmail) {
      _pending = widget.account.pendingEmail;
    }
  }

  Future<void> _restore() async {
    try {
      final id = await widget.repository.pendingMailTask(widget.session);
      if (mounted && id != null) {
        setState(() => _task = id);
        await _check();
      }
    } on Object {
      if (mounted) {
        setState(() => _error = trNow(context, 'mailStatusUnavailable'));
      }
    }
  }

  Future<void> _check() async {
    final id = _task;
    if (id == null || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await widget.repository.emailStatus(widget.session, id);
      if (!mounted) return;
      setState(() {
        _state = result['State']?.toString() ?? '';
        _error = (result['Error']?.toString() ?? '').isEmpty
            ? null
            : AppStrings.snapshot(context)
                  .errorMessage(ApiException(result['Error'].toString()));
        if (_state == 'sent' || _state == 'failed') _task = null;
      });
      if (_task != null) _timer = Timer(const Duration(seconds: 2), _check);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = AppStrings.snapshot(context).errorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _send({bool current = false}) async {
    if (_sending || _task != null) return;
    if (current) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'verifyEmail')),
          content: Text(
            tr(context, 'verifyEmailConfirm', [widget.account.email]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'm0026')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'sendVerification')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    } else if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
            .hasMatch(_email.text.trim()) ||
        _password.text.isEmpty) {
      setState(() => _error = trNow(context, 'emailChangeInvalid'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _state = '';
    });
    try {
      final locale = AppStrings.snapshot(context).locale.languageCode == 'zh'
          ? 'zh-CN'
          : 'en-US';
      final result = await widget.repository.queueVerification(
        widget.session,
        current: current,
        email: _email.text,
        password: _password.text,
        language: locale,
      );
      if (!mounted) return;
      _password.clear();
      setState(() {
        _task = result['TaskId'] as String;
        _state = 'queued';
        _pending = result['PendingEmail']?.toString() ?? '';
      });
      _timer = Timer(const Duration(seconds: 1), _check);
    } on Object catch (error) {
      if (mounted) {
        _password.clear();
        setState(
          () => _error = AppStrings.snapshot(context).errorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _sending || _task != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${tr(context, 'currentEmail')}：${widget.account.email}'),
            if (!widget.account.verified && widget.account.email.isNotEmpty)
              TextButton(
                onPressed: busy ? null : () => _send(current: true),
                child: Text(tr(context, 'emailUnverified')),
              )
            else if (widget.account.verified)
              Text('  ${tr(context, 'emailVerified')}'),
          ],
        ),
        if (_pending.isNotEmpty) Text(tr(context, 'pendingEmail', [_pending])),
        Text(
          tr(context, 'oldEmailRemainsValid'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextField(
          controller: _email,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: tr(context, 'm0022')),
        ),
        TextField(
          controller: _password,
          enabled: !busy,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(labelText: tr(context, 'm0021')),
        ),
        TextButton(
          onPressed: busy ? null : () => _send(),
          child: Text(tr(context, 'sendVerification')),
        ),
        if (_sending || _checking) const LinearProgressIndicator(),
        if (_state.isNotEmpty)
          Text(
            tr(context, 'mailState_$_state'),
            style: TextStyle(
              color: _state == 'failed'
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        if (_error != null)
          Text(
            trMessage(context, _error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_task != null && _error != null)
          TextButton(
            onPressed: _checking ? null : _check,
            child: Text(tr(context, 'retryMailStatus')),
          ),
      ],
    );
  }
}
