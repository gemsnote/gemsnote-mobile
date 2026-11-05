import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/app_lock.dart';
import 'startup_page.dart';

class AppLockGate extends StatefulWidget {
  const AppLockGate({required this.controller, required this.child, super.key});

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _backgrounded = false;
  bool _authenticationReturnPending = false;
  bool _unlockOnResume = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _backgrounded =
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  Future<void> _initialize() =>
      widget.controller.initialize(trNow(context, 'appLockReason'));

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      if (widget.controller.authenticating) {
        _authenticationReturnPending = true;
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgrounded = true;
      // Credential activities can deliver their result before the final
      // hidden/paused notifications. Keep that entire lifecycle transition
      // attached to the original verification, even after its Future ends.
      if (widget.controller.authenticating || _authenticationReturnPending) {
        _authenticationReturnPending = true;
      } else {
        widget.controller.backgrounded();
        _unlockOnResume = widget.controller.locked;
      }
      _changed();
    } else if (state == AppLifecycleState.resumed) {
      final shouldUnlock = _unlockOnResume && !_authenticationReturnPending;
      _backgrounded = false;
      _authenticationReturnPending = false;
      _unlockOnResume = false;
      _changed();
      if (shouldUnlock &&
          widget.controller.locked &&
          !widget.controller.authenticating) {
        unawaited(widget.controller.unlock(trNow(context, 'appLockReason')));
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hidden =
        !widget.controller.ready ||
        widget.controller.locked ||
        (_backgrounded && widget.controller.enabled);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Keep Navigator and editors mounted, including routes pushed above home.
        Offstage(
          offstage: hidden,
          child: TickerMode(
            enabled: !hidden,
            child: ExcludeFocus(excluding: hidden, child: widget.child),
          ),
        ),
        if (hidden) Positioned.fill(child: _lockedScreen(context)),
      ],
    );
  }

  Widget _lockedScreen(BuildContext context) {
    if (!widget.controller.ready) {
      return const StartupPage();
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 16),
                Text(tr(context, 'appLocked')),
                if (widget.controller.error != null) ...[
                  const SizedBox(height: 8),
                  Text(tr(context, widget.controller.error!)),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: widget.controller.authenticating
                      ? null
                      : () => widget.controller.unlock(
                          trNow(context, 'appLockReason'),
                        ),
                  icon: const Icon(Icons.fingerprint),
                  label: Text(tr(context, 'appUnlock')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
