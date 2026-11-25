/// Root widget `DynaOpsApp`: `MaterialApp.router` wired to the go_router from
/// `core/router`, the light/dark themes from `core/theme`, the generated
/// `AppLocalizations`, and the one root-level Cubit (`LocaleCubit`) that
/// switches the native locale to the language picked in Angular. It owns the
/// `PermissionGate` that keeps a tracked rep on the walkthrough until tracking has
/// every permission it needs, and the `UpdateGate` that blocks the app on a
/// mandatory update. It also asks the server for an update on launch and on
/// every return to the foreground, and opens `/update` over the current
/// screen when an optional one is found.
///
/// Why it exists: keeps `main.dart` to bootstrapping only; feature Cubits are
/// provided per route, never here (flutter-cubit-architecture).
/// Status: used — created by `main.dart` on every launch.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'core/di/service_locator.dart';
import 'core/router/app_router.dart';
import 'core/router/permission_gate.dart';
import 'core/router/update_gate.dart';
import 'core/theme/app_theme.dart';
import 'features/app_update/data/app_update_repository.dart';
import 'features/locale/cubit/locale_cubit.dart';
import 'l10n/generated/app_localizations.dart';

class DynaOpsApp extends StatefulWidget {
  const DynaOpsApp({super.key});

  @override
  State<DynaOpsApp> createState() => _DynaOpsAppState();
}

class _DynaOpsAppState extends State<DynaOpsApp> {
  final PermissionGate _gate = PermissionGate(getIt(), getIt());
  final UpdateGate _updateGate = UpdateGate(getIt());
  late final GoRouter _router = createAppRouter(_gate, _updateGate);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _updateGate.addListener(_offerOptionalUpdate);
    _lifecycle = AppLifecycleListener(onResume: _checkForUpdate);
    _checkForUpdate();
  }

  /// On launch and on every resume; the gate hears the answer.
  void _checkForUpdate() => unawaited(getIt<AppUpdateRepository>().check());

  /// Pushed (not redirected), so "Later" returns to the web app as it was.
  void _offerOptionalUpdate() {
    if (_updateGate.takeOptionalOffer()) unawaited(_router.push<void>(UpdateGate.updatePath));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _updateGate.removeListener(_offerOptionalUpdate);
    _router.dispose();
    _updateGate.dispose();
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // LocaleCubit is the only root-level Cubit; feature Cubits live on routes.
    return BlocProvider(
      create: (_) => getIt<LocaleCubit>(),
      child: BlocBuilder<LocaleCubit, Locale?>(
        builder: (context, locale) => MaterialApp.router(
          onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: _router,
        ),
      ),
    );
  }
}
