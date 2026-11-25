/// `AppUpdateCubit`: drives the update screen. On start it looks at what is
/// already on disk for the pending update — a finished APK goes straight to
/// "install" (never downloaded twice), a partial one offers "resume". It runs
/// the download with progress, pauses it, turns a failure into a retryable
/// state that keeps the bytes received, opens the installer, and lets an
/// optional update be dismissed (a mandatory one cannot be).
///
/// Why it exists: the order and rules of download → verify → install are
/// logic, kept out of the screen.
/// Status: used — provided on `/update`; tested in
/// `test/features/app_update/cubit/app_update_cubit_test.dart`.
library;

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/failure.dart';
import '../data/apk_download_repository.dart';
import '../data/app_update_model.dart';
import '../data/app_update_repository.dart';
import 'app_update_state.dart';

class AppUpdateCubit extends Cubit<AppUpdateState> {
  AppUpdateCubit(this._updates, this._downloads) : super(const AppUpdateLoading());

  final AppUpdateRepository _updates;
  final ApkDownloadRepository _downloads;

  /// Shows the pending update in the state its files are in.
  Future<void> start() async {
    final update = _updates.pending;
    if (update == null) return emit(const AppUpdateClosed());
    final local = await _local(update);
    if (isClosed) return;
    if (local.complete) {
      emit(AppUpdateReady(update));
    } else if (local.receivedBytes > 0) {
      emit(AppUpdatePaused(update, receivedBytes: local.receivedBytes, totalBytes: update.sizeBytes ?? 0));
    } else {
      emit(AppUpdateAvailable(update));
    }
  }

  /// "Update", "Resume" and "Retry": downloads from the bytes already on disk.
  Future<void> download() async {
    final current = state;
    if (current is! AppUpdateAvailable && current is! AppUpdatePaused && current is! AppUpdateFailed) return;
    final update = (current as AppUpdateShown).update;
    var received = current is AppUpdateTransfer ? current.receivedBytes : 0;
    var total = current is AppUpdateTransfer ? current.totalBytes : update.sizeBytes ?? 0;
    emit(AppUpdateDownloading(update, receivedBytes: received, totalBytes: total));
    try {
      final finished = await _downloads.download(
        update,
        onProgress: (receivedBytes, totalBytes) {
          received = receivedBytes;
          total = totalBytes;
          if (!isClosed) emit(AppUpdateDownloading(update, receivedBytes: received, totalBytes: total));
        },
      );
      if (isClosed) return;
      emit(
        finished ? AppUpdateReady(update) : AppUpdatePaused(update, receivedBytes: received, totalBytes: total),
      );
    } on Failure catch (failure) {
      // A file that failed verification was deleted: show what is really left.
      final local = await _local(update);
      if (isClosed) return;
      emit(
        AppUpdateFailed(
          update,
          receivedBytes: local.receivedBytes,
          totalBytes: total,
          reason: switch (failure) {
            NetworkFailure() || TimeoutFailure() => AppUpdateFailureReason.network,
            _ => AppUpdateFailureReason.other,
          },
        ),
      );
    }
  }

  /// Stops the running download; [download] emits the paused state.
  void pause() {
    if (state is AppUpdateDownloading) _downloads.pause();
  }

  /// Opens Android's installer on the downloaded APK.
  Future<void> install() async {
    final current = state;
    if (current is! AppUpdateReady) return;
    // The file may have been removed since (storage cleaner): start again.
    if (!(await _local(current.update)).complete) return start();
    try {
      await _downloads.install(current.update);
      if (!isClosed) emit(AppUpdateReady(current.update));
    } on Failure {
      if (!isClosed) emit(AppUpdateReady(current.update, installFailed: true));
    }
  }

  /// "Later" — only an optional update can be put off.
  void dismiss() {
    final current = state;
    if (current is AppUpdateShown && current.update.mandatory) return;
    _downloads.pause();
    emit(const AppUpdateClosed());
  }

  Future<ApkLocalStatus> _local(AppUpdateModel update) async {
    try {
      return await _downloads.status(update);
    } on Failure {
      return (complete: false, receivedBytes: 0);
    }
  }

  @override
  Future<void> close() {
    // Leaving the screen pauses; the bytes stay for the next visit.
    _downloads.pause();
    return super.close();
  }
}
