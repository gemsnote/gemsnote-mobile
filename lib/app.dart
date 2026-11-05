import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_strings.dart';
import 'l10n/language_controller.dart';

import 'dart:async';

import 'repositories/auth_repository.dart';
import 'ui/login_page.dart';
import 'ui/startup_page.dart';
import 'ui/workspace_page.dart';
import 'services/home_widget.dart';
import 'services/native_language.dart';
import 'services/deep_links.dart';
import 'services/app_lock.dart';
import 'ui/app_lock_gate.dart';

class GemsnoteApp extends StatefulWidget {
  const GemsnoteApp({required this.repository, super.key});
  final AuthRepository repository;
  @override
  State<GemsnoteApp> createState() => _GemsnoteAppState();
}

class _GemsnoteAppState extends State<GemsnoteApp> {
  late final LanguageController _language;
  late final AppLockController _appLock;
  @override
  void initState() {
    super.initState();
    _appLock = AppLockController(
      load: widget.repository.appLockEnabled,
      save: widget.repository.setAppLockEnabled,
    );
    _language = LanguageController(
      load: widget.repository.languagePreference,
      save: widget.repository.setLanguagePreference,
      applyNative: setNativeLanguage,
    );
    unawaited(_language.restore());
  }

  @override
  void dispose() {
    _language.dispose();
    _appLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LanguageScope(
    controller: _language,
    child: ListenableBuilder(
      listenable: _language,
      builder: (context, _) => MaterialApp(
        title: 'Gemsnote',
        debugShowCheckedModeBanner: false,
        locale: _language.locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        localeListResolutionCallback: (locales, _) =>
            Locale(locales?.firstOrNull?.languageCode == 'zh' ? 'zh' : 'en'),
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff173d38),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xfff6f4eb),
          useMaterial3: true,
        ),
        builder: (context, child) => Column(
          children: [
            if (_language.loadError != null || _language.nativeError != null)
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: SafeArea(
                  bottom: false,
                  child: ListTile(
                    title: Text(
                      tr(
                        context,
                        _language.loadError != null
                            ? 'languageLoadFailed'
                            : 'nativeLanguageFailed',
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: _language.loadError != null
                          ? _language.restore
                          : _language.refreshNative,
                      child: Text(tr(context, 'languageRetry')),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: AppLockGate(controller: _appLock, child: child!),
            ),
          ],
        ),
        home: _RootGate(
          repository: widget.repository,
          appLock: _appLock,
          languageReady: _language.ready,
        ),
      ),
    ),
  );
}

class _RootGate extends StatefulWidget {
  const _RootGate({
    required this.repository,
    required this.appLock,
    required this.languageReady,
  });

  final AuthRepository repository;
  final AppLockController appLock;
  final bool languageReady;

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  final _homeWidget = HomeWidgetController();
  final _deepLinks = DeepLinkController();
  StoredSession? _session;
  var _ready = false;
  bool _restoreFailed = false;
  bool _restoring = false;
  bool _freshLogin = false;
  int _sessionGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_deepLinks.start());
    _restore();
  }

  Future<void> _restore() async {
    if (_restoring) return;
    _restoring = true;
    if (mounted) setState(() => _restoreFailed = false);
    try {
      final session = await widget.repository.restore();
      if (mounted) {
        _bindWidget(session);
        setState(() {
          _session = session;
          _ready = true;
        });
      }
    } on Object {
      if (mounted) setState(() => _restoreFailed = true);
    } finally {
      _restoring = false;
    }
  }

  void _bindWidget(StoredSession? session) {
    unawaited(
      _homeWidget.activate(
        session,
        session == null
            ? null
            : () => widget.repository.notes(session.account.cacheKey),
      ),
    );
  }

  @override
  void dispose() {
    _homeWidget.dispose();
    _deepLinks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.languageReady || !_ready) {
      return StartupPage(
        errorKey: widget.languageReady && _restoreFailed
            ? 'startupSessionFailed'
            : null,
        onRetry: _restore,
      );
    }
    if (_session == null) {
      return LoginPage(
        repository: widget.repository,
        onSessionRestored: (session) => setState(() {
          _bindWidget(session);
          _session = session;
          _freshLogin = false;
        }),
        onSignedIn: (session) => setState(() {
          _bindWidget(session);
          _session = session;
          _freshLogin = true;
        }),
      );
    }
    return WorkspacePage(
      homeWidget: _homeWidget,
      deepLinks: _deepLinks,
      appLock: widget.appLock,
      key: ValueKey((_session!.account.cacheKey, _sessionGeneration)),
      onSessionChanged: (session) => setState(() {
        _bindWidget(session);
        _sessionGeneration++;
        _session = session;
        _freshLogin = false;
      }),
      repository: widget.repository,
      session: _session!,
      refreshAvatarOnStart: _freshLogin,
      onSignedOut: () {
        unawaited(widget.appLock.clear());
        setState(() {
          _bindWidget(null);
          _session = null;
        });
      },
    );
  }
}
