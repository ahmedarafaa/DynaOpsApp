/// `AppUpdateScreen`: the localised update screen — what the update is
/// (version, release notes), then one action per state: "Update", the
/// download progress with "Pause", "Resume" after a pause, "Retry" after a
/// failure, and "Install" once the APK is on disk. An optional update also has
/// "Later" and closes on back; a mandatory one has neither, and back leaves
/// the app.
///
/// Why it exists: the app is installed from an APK, so updating happens here
/// instead of in a store.
/// Status: used — mounted on `/update`; `UpdateGate` redirects here for a
/// mandatory update and `app.dart` pushes it for an optional one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/feedback/loading_overlay.dart';
import '../cubit/app_update_cubit.dart';
import '../cubit/app_update_state.dart';
import 'widgets/update_download_progress.dart';

class AppUpdateScreen extends StatelessWidget {
  const AppUpdateScreen({super.key});

  void _close(BuildContext context) => context.canPop() ? context.pop() : context.go('/');

  /// Back can never get around a mandatory update: it leaves the app.
  void _onBack(BuildContext context) {
    final state = context.read<AppUpdateCubit>().state;
    if (state is AppUpdateShown && state.update.mandatory) {
      SystemNavigator.pop();
    } else {
      context.read<AppUpdateCubit>().dismiss();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AppUpdateCubit, AppUpdateState>(
      listenWhen: (_, state) => state is AppUpdateClosed,
      listener: (context, _) => _close(context),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onBack(context);
        },
        child: Scaffold(
          body: SafeArea(
            child: BlocBuilder<AppUpdateCubit, AppUpdateState>(
              builder: (context, state) => switch (state) {
                AppUpdateLoading() || AppUpdateClosed() => const LoadingOverlay(),
                AppUpdateShown() => _UpdateView(state: state),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateView extends StatelessWidget {
  const _UpdateView({required this.state});
  final AppUpdateShown state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cubit = context.read<AppUpdateCubit>();
    final update = state.update;
    final notes = update.notesFor(Localizations.localeOf(context).languageCode);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.system_update_outlined, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 24),
              Text(
                update.mandatory ? l10n.updateTitleMandatory : l10n.updateTitleOptional,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                update.mandatory
                    ? l10n.updateBodyMandatory(update.versionName)
                    : l10n.updateBodyOptional(update.versionName),
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              if (notes != null) ...[
                const SizedBox(height: 24),
                Text(l10n.updateWhatsNew, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(notes, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 32),
              ..._stateSection(l10n, theme, cubit),
              if (!update.mandatory) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: cubit.dismiss, child: Text(l10n.updateLater)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The progress (when a download was started) and the state's one action.
  List<Widget> _stateSection(AppLocalizations l10n, ThemeData theme, AppUpdateCubit cubit) {
    final current = state;
    return switch (current) {
      AppUpdateAvailable() => [FilledButton(onPressed: cubit.download, child: Text(l10n.updateNow))],
      AppUpdateDownloading() => [
          _progress(l10n, current),
          const SizedBox(height: 24),
          OutlinedButton(onPressed: cubit.pause, child: Text(l10n.updatePause)),
        ],
      AppUpdatePaused() => [
          _progress(l10n, current, message: l10n.updatePaused),
          const SizedBox(height: 24),
          FilledButton(onPressed: cubit.download, child: Text(l10n.updateResume)),
        ],
      AppUpdateFailed(:final reason) => [
          _progress(
            l10n,
            current,
            isError: true,
            message: switch (reason) {
              AppUpdateFailureReason.network => l10n.updateFailedNetwork,
              AppUpdateFailureReason.other => l10n.updateFailedOther,
            },
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: cubit.download, child: Text(l10n.retry)),
        ],
      AppUpdateReady(:final installFailed) => [
          Text(
            installFailed ? l10n.updateInstallFailed : l10n.updateReady,
            style: theme.textTheme.bodyMedium?.copyWith(color: installFailed ? theme.colorScheme.error : null),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: cubit.install, child: Text(l10n.updateInstall)),
        ],
    };
  }

  Widget _progress(AppLocalizations l10n, AppUpdateTransfer transfer, {String? message, bool isError = false}) {
    final received = _megabytes(transfer.receivedBytes);
    return UpdateDownloadProgress(
      fraction: transfer.fraction,
      sizeLabel: transfer.totalBytes > 0
          ? l10n.updateProgress(received, _megabytes(transfer.totalBytes))
          : l10n.updateProgressUnknown(received),
      message: message,
      isError: isError,
    );
  }

  static String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
