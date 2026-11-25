/// `bloc_test` coverage for `AppUpdateCubit`: it opens on what is on disk
/// (install when downloaded, resume when partial, update otherwise, closed
/// when nothing is pending); a download reports progress and ends ready,
/// paused or failed with the bytes kept; retry continues; install reports a
/// failure and starts over when the file is gone; only an optional update can
/// be dismissed.
///
/// Status: active — part of `flutter test`.
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:dynaopsapp/core/network/failure.dart';
import 'package:dynaopsapp/features/app_update/cubit/app_update_cubit.dart';
import 'package:dynaopsapp/features/app_update/cubit/app_update_state.dart';
import 'package:dynaopsapp/features/app_update/data/apk_download_repository.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_model.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockUpdates extends Mock implements AppUpdateRepository {}

class _MockDownloads extends Mock implements ApkDownloadRepository {}

typedef _OnProgress = void Function(int receivedBytes, int totalBytes);

const optional = AppUpdateModel(
  versionCode: 12,
  versionName: '1.3.0',
  apkUrl: 'https://files.example.com/app.apk',
  sizeBytes: 1000,
);
const mandatory = AppUpdateModel(
  versionCode: 12,
  versionName: '1.3.0',
  apkUrl: 'https://files.example.com/app.apk',
  sizeBytes: 1000,
  mandatory: true,
);

void main() {
  late _MockUpdates updates;
  late _MockDownloads downloads;

  setUpAll(() {
    registerFallbackValue(optional);
    void onProgress(int receivedBytes, int totalBytes) {}
    registerFallbackValue(onProgress);
  });

  setUp(() {
    updates = _MockUpdates();
    downloads = _MockDownloads();
    when(() => updates.pending).thenReturn(optional);
    when(() => downloads.pause()).thenReturn(null);
    onDiskFor(downloads);
  });

  AppUpdateCubit build() => AppUpdateCubit(updates, downloads);

  /// The download reports [steps] and then finishes with [result] (or throws).
  void downloadRuns(List<int> steps, {bool result = true, Failure? failure}) {
    when(() => downloads.download(any(), onProgress: any(named: 'onProgress'))).thenAnswer((invocation) async {
      final onProgress = invocation.namedArguments[#onProgress] as _OnProgress;
      for (final received in steps) {
        onProgress(received, 1000);
      }
      if (failure != null) throw failure;
      return result;
    });
  }

  blocTest<AppUpdateCubit, AppUpdateState>(
    'nothing pending → closed',
    setUp: () => when(() => updates.pending).thenReturn(null),
    build: build,
    act: (cubit) => cubit.start(),
    expect: () => [const AppUpdateClosed()],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'nothing on disk → available',
    build: build,
    act: (cubit) => cubit.start(),
    expect: () => [const AppUpdateAvailable(optional)],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'already downloaded → ready to install, no download',
    setUp: () => onDiskFor(downloads, complete: true),
    build: build,
    act: (cubit) => cubit.start(),
    expect: () => [const AppUpdateReady(optional)],
    verify: (_) => verifyNever(() => downloads.download(any(), onProgress: any(named: 'onProgress'))),
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'partial file → paused at its size',
    setUp: () => onDiskFor(downloads, receivedBytes: 400),
    build: build,
    act: (cubit) => cubit.start(),
    expect: () => [const AppUpdatePaused(optional, receivedBytes: 400, totalBytes: 1000)],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'download reports progress and ends ready',
    setUp: () => downloadRuns([500, 1000]),
    build: build,
    seed: () => const AppUpdateAvailable(optional),
    act: (cubit) => cubit.download(),
    expect: () => [
      const AppUpdateDownloading(optional, receivedBytes: 0, totalBytes: 1000),
      const AppUpdateDownloading(optional, receivedBytes: 500, totalBytes: 1000),
      const AppUpdateDownloading(optional, receivedBytes: 1000, totalBytes: 1000),
      const AppUpdateReady(optional),
    ],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'a paused download keeps its progress; pause reaches the repository',
    setUp: () => downloadRuns([300], result: false),
    build: build,
    seed: () => const AppUpdateAvailable(optional),
    act: (cubit) => cubit.download(),
    skip: 2,
    expect: () => [const AppUpdatePaused(optional, receivedBytes: 300, totalBytes: 1000)],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'a network failure is retryable from the bytes on disk',
    setUp: () {
      downloadRuns([300], failure: const NetworkFailure());
      onDiskFor(downloads, receivedBytes: 300);
    },
    build: build,
    seed: () => const AppUpdateAvailable(optional),
    act: (cubit) => cubit.download(),
    skip: 2,
    expect: () => [
      const AppUpdateFailed(
        optional,
        receivedBytes: 300,
        totalBytes: 1000,
        reason: AppUpdateFailureReason.network,
      ),
    ],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'retry after a failure resumes from where it stopped',
    setUp: () => downloadRuns([1000]),
    build: build,
    seed: () => const AppUpdateFailed(
      optional,
      receivedBytes: 300,
      totalBytes: 1000,
      reason: AppUpdateFailureReason.other,
    ),
    act: (cubit) => cubit.download(),
    expect: () => [
      const AppUpdateDownloading(optional, receivedBytes: 300, totalBytes: 1000),
      const AppUpdateDownloading(optional, receivedBytes: 1000, totalBytes: 1000),
      const AppUpdateReady(optional),
    ],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'install failure is shown on the ready state',
    setUp: () {
      onDiskFor(downloads, complete: true);
      when(() => downloads.install(any())).thenThrow(const PlatformFailure('no'));
    },
    build: build,
    seed: () => const AppUpdateReady(optional),
    act: (cubit) => cubit.install(),
    expect: () => [const AppUpdateReady(optional, installFailed: true)],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'install with the file gone starts over',
    build: build,
    seed: () => const AppUpdateReady(optional),
    act: (cubit) => cubit.install(),
    expect: () => [const AppUpdateAvailable(optional)],
    verify: (_) => verifyNever(() => downloads.install(any())),
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'an optional update can be dismissed',
    build: build,
    seed: () => const AppUpdateAvailable(optional),
    act: (cubit) => cubit.dismiss(),
    expect: () => [const AppUpdateClosed()],
  );

  blocTest<AppUpdateCubit, AppUpdateState>(
    'a mandatory update cannot be dismissed',
    build: build,
    seed: () => const AppUpdateAvailable(mandatory),
    act: (cubit) => cubit.dismiss(),
    expect: () => <AppUpdateState>[],
  );
}

/// What `status` reports for any update.
void onDiskFor(ApkDownloadRepository downloads, {bool complete = false, int receivedBytes = 0}) {
  when(() => downloads.status(any())).thenAnswer((_) async => (complete: complete, receivedBytes: receivedBytes));
}
