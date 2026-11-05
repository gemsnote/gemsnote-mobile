import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/models/account.dart';
import '../repositories/auth_repository.dart';
import 'account_avatar.dart';
import 'user_groups_page.dart';
import 'email_verification.dart';
import 'password_change_dialog.dart';
import 'avatar_upload_dialog.dart';
import 'avatar_crop_dialog.dart';
import '../services/avatar_picker.dart';
import '../services/app_lock.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.repository,
    required this.session,
    this.avatarPicker,
    this.appLock,
  });
  final AuthRepository repository;
  final StoredSession session;
  final AvatarPicker? avatarPicker;
  final AppLockController? appLock;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late Account _account;
  final _username = TextEditingController();
  bool _busy = true;
  String? _error;
  Uint8List? _avatar;
  bool _passwordChanged = false;

  void _appLockChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleAppLock(bool enabled) async {
    final lock = widget.appLock;
    if (lock == null) return;
    final changed = await lock.setEnabled(
      enabled,
      trNow(context, enabled ? 'appLockEnableReason' : 'appLockDisableReason'),
    );
    if (!changed && mounted && lock.error != null) {
      setState(() => _error = lock.error);
    }
  }

  Future<void> _saveUsername() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.updateUsername(
        widget.session,
        username: _username.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr(context, 'm0042'))));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = AppStrings.snapshot(context).errorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _refresh();
  }

  Future<void> _chooseAvatar() async {
    final picker =
        widget.avatarPicker ??
        AvatarPicker(strings: AppStrings.snapshot(context));
    if (!picker.cameraSupported) {
      await _uploadAvatar();
      return;
    }
    final camera = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr(context, 'm0038')),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(tr(context, 'm0039')),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (camera != null && mounted) await _uploadAvatar(camera: camera);
  }

  Future<void> _uploadAvatar({bool camera = false}) async {
    if (_busy || _passwordChanged) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    bool uploaded = false;
    try {
      final picker =
          widget.avatarPicker ??
          AvatarPicker(strings: AppStrings.snapshot(context));
      final source = await (camera ? picker.capture() : picker.pick());
      if (source == null || !mounted) return;
      final bytes = await showDialog<Uint8List>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AvatarCropDialog(bytes: source),
      );
      if (bytes == null || !mounted) return;
      uploaded =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AvatarUploadDialog(
              bytes: bytes,
              upload: () =>
                  widget.repository.uploadAvatar(widget.session, bytes: bytes),
            ),
          ) ==
          true;
      if (uploaded && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trNow(context, 'm0027'))));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = trNow(context, 'm0028', [error]));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (uploaded && mounted) await _refresh();
  }

  Future<void> _finishPasswordChange() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The server revoked the old token. Keep dirty notes, don't try uploading.
      await widget.repository.logout(
        widget.session,
        discardSessionWithPendingChanges: true,
      );
      if (mounted) Navigator.pop(context, true);
    } on Object {
      if (mounted) setState(() => _error = trNow(context, 'm0029'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.appLock?.addListener(_appLockChanged);
    _account = widget.session.account;
    _username.text = _account.username;
    _loadCache();
  }

  @override
  void dispose() {
    widget.appLock?.removeListener(_appLockChanged);
    _username.dispose();
    super.dispose();
  }

  Future<void> _loadCache() async {
    try {
      final profile = await widget.repository.cachedProfile(widget.session);
      final avatar = await widget.repository.cachedAvatar(widget.session);
      if (mounted) {
        setState(() {
          _account = profile;
          _username.text = profile.username;
          _avatar = avatar;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0030', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.refreshAccountPresentation(widget.session);
      final profile = await widget.repository.cachedProfile(widget.session);
      if (mounted) {
        setState(() {
          _account = profile;
          _username.text = profile.username;
        });
      }
      try {
        final avatar = await widget.repository.cachedAvatar(widget.session);
        if (mounted) setState(() => _avatar = avatar);
      } on Object catch (error) {
        if (mounted) setState(() => _error = trNow(context, 'm0031', [error]));
      }
    } catch (error) {
      if (mounted) setState(() => _error = trNow(context, 'm0032', [error]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        SelectableText(value.isEmpty ? trNow(context, 'm0033') : value),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_passwordChanged,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'm0034')),
        actions: [
          IconButton(
            tooltip: tr(context, 'm0035'),
            onPressed: _busy || _passwordChanged ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _passwordChanged
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tr(context, 'm0036')),
                  if (_error != null) Text(trMessage(context, _error!)),
                  FilledButton(
                    onPressed: _busy ? null : _finishPasswordChange,
                    child: Text(tr(context, 'm0037')),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_busy) const LinearProgressIndicator(),
                Center(
                  child: IconButton(
                    tooltip: tr(context, 'm0038'),
                    onPressed: _busy ? null : _chooseAvatar,
                    icon: AccountAvatar(bytes: _avatar, size: 80),
                  ),
                ),
                if (_error != null)
                  Text(
                    trMessage(context, _error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                _field(tr(context, 'm0040'), _account.server.toString()),
                TextField(
                  controller: _username,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: tr(context, 'm0041'),
                    suffixIcon: IconButton(
                      tooltip: tr(context, 'm0017'),
                      onPressed: _busy ? null : _saveUsername,
                      icon: const Icon(Icons.check),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                EmailVerification(
                  repository: widget.repository,
                  session: widget.session,
                  account: _account,
                ),
                _field(tr(context, 'm0045'), _account.userId),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(tr(context, 'userGroups')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => UserGroupsPage(
                              repository: widget.repository,
                              session: widget.session,
                            ),
                          ),
                        ),
                ),
                if (widget.appLock case final lock?)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.fingerprint),
                    title: Text(tr(context, 'appLockSetting')),
                    subtitle: Text(
                      tr(
                        context,
                        lock.supported
                            ? 'appLockSettingDescription'
                            : 'appLockUnavailable',
                      ),
                    ),
                    value: lock.enabled,
                    onChanged:
                        lock.ready && lock.supported && !lock.authenticating
                        ? _toggleAppLock
                        : null,
                  ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final changed = await showDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => PasswordChangeDialog(
                              identity: _account.email.isEmpty
                                  ? _account.username
                                  : _account.email,
                              save: (identity, oldPassword, password) =>
                                  widget.repository.changePassword(
                                    widget.session,
                                    identity: identity,
                                    oldPassword: oldPassword,
                                    password: password,
                                  ),
                            ),
                          );
                          if (changed == true && mounted) {
                            setState(() => _passwordChanged = true);
                            await _finishPasswordChange();
                          }
                        },
                  child: Text(tr(context, 'm0046')),
                ),
                const Divider(),
                Text(tr(context, 'm0047')),
              ],
            ),
    ),
  );
}
