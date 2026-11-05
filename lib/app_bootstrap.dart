import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app.dart';
import 'l10n/app_strings.dart';
import 'repositories/auth_repository.dart';
import 'ui/startup_page.dart';

class GemsnoteBootstrap extends StatefulWidget {
  const GemsnoteBootstrap({super.key, required this.initialize});
  final Future<AuthRepository> Function() initialize;

  @override
  State<GemsnoteBootstrap> createState() => _GemsnoteBootstrapState();
}

class _GemsnoteBootstrapState extends State<GemsnoteBootstrap> {
  AuthRepository? _repository;
  bool _failed = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    // Submit the first frame before any database migrations or plugin work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (_running) return;
    setState(() {
      _running = true;
      _failed = false;
    });
    try {
      final repository = await widget.initialize();
      if (mounted) setState(() => _repository = repository);
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    if (repository != null) return GemsnoteApp(repository: repository);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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
        colorScheme: ColorScheme.fromSeed(seedColor: StartupPage.background),
        useMaterial3: true,
      ),
      home: StartupPage(
        errorKey: _failed ? 'startupFailed' : null,
        onRetry: _start,
      ),
    );
  }
}
