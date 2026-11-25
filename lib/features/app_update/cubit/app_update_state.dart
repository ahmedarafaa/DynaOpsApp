/// `AppUpdateState`: sealed states of the update screen — `AppUpdateLoading`
/// (looking at what is on disk), `AppUpdateAvailable` (nothing downloaded),
/// `AppUpdateDownloading` / `AppUpdatePaused` / `AppUpdateFailed` (a transfer
/// with its byte counts), `AppUpdateReady` (the verified APK is on disk; the
/// installer can be opened) and `AppUpdateClosed` (leave the screen).
///
/// Why it exists: sealed, value-equal states (flutter-cubit-architecture).
/// Status: used — emitted by `AppUpdateCubit`, rendered by `AppUpdateScreen`.
library;

import 'package:equatable/equatable.dart';

import '../data/app_update_model.dart';

/// Why a download stopped, for the message shown with "Retry".
enum AppUpdateFailureReason { network, other }

sealed class AppUpdateState extends Equatable {
  const AppUpdateState();
  @override
  List<Object?> get props => [];
}

final class AppUpdateLoading extends AppUpdateState {
  const AppUpdateLoading();
}

/// There is nothing (left) to show: the screen closes itself.
final class AppUpdateClosed extends AppUpdateState {
  const AppUpdateClosed();
}

/// Every state that shows an update.
sealed class AppUpdateShown extends AppUpdateState {
  const AppUpdateShown(this.update);
  final AppUpdateModel update;

  @override
  List<Object?> get props => [update];
}

final class AppUpdateAvailable extends AppUpdateShown {
  const AppUpdateAvailable(super.update);
}

/// A started download, running or not.
sealed class AppUpdateTransfer extends AppUpdateShown {
  const AppUpdateTransfer(super.update, {required this.receivedBytes, required this.totalBytes});

  final int receivedBytes;

  /// 0 when the size is not known.
  final int totalBytes;

  /// 0..1, or -1 when the size is not known.
  double get fraction => totalBytes <= 0 ? -1 : (receivedBytes / totalBytes).clamp(0, 1).toDouble();

  @override
  List<Object?> get props => [update, receivedBytes, totalBytes];
}

final class AppUpdateDownloading extends AppUpdateTransfer {
  const AppUpdateDownloading(super.update, {required super.receivedBytes, required super.totalBytes});
}

final class AppUpdatePaused extends AppUpdateTransfer {
  const AppUpdatePaused(super.update, {required super.receivedBytes, required super.totalBytes});
}

final class AppUpdateFailed extends AppUpdateTransfer {
  const AppUpdateFailed(
    super.update, {
    required super.receivedBytes,
    required super.totalBytes,
    required this.reason,
  });

  final AppUpdateFailureReason reason;

  @override
  List<Object?> get props => [...super.props, reason];
}

final class AppUpdateReady extends AppUpdateShown {
  const AppUpdateReady(super.update, {this.installFailed = false});

  /// The installer could not be opened on the last try.
  final bool installFailed;

  @override
  List<Object?> get props => [update, installFailed];
}
