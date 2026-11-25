/// `ApkDownloadRepository`: the update's APK on disk. Downloads it into the
/// app's private `updates/` folder as `dynaops-<versionCode>.apk.part`,
/// resuming from the bytes already there (`Range`), checks size and SHA-256,
/// and only then renames it to `dynaops-<versionCode>.apk` — so a finished
/// file is always a verified one and is never downloaded twice. Also reports
/// what is on disk, pauses a running download, hands the APK to Android's
/// installer and deletes files of other versions.
///
/// Why it exists: the app is distributed outside the Play Store, so it has to
/// fetch and install its own updates.
/// Status: used — by `AppUpdateCubit` and `AppUpdateRepository` (clean-up);
/// tested in `test/features/app_update/data/apk_download_repository_test.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/network/failure.dart';
import 'app_update_api.dart';
import 'app_update_model.dart';

/// What is on disk for one update.
typedef ApkLocalStatus = ({bool complete, int receivedBytes});

class ApkDownloadRepository {
  ApkDownloadRepository(this._api, this._logger, {Future<Directory> Function()? baseDirectory})
      : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory;

  static const apkMimeType = 'application/vnd.android.package-archive';

  /// At most one progress callback per this interval (plus the first and last).
  static const _progressEvery = Duration(milliseconds: 150);

  final AppUpdateApi _api;
  final AppLogger _logger;
  final Future<Directory> Function() _baseDirectory;
  CancelToken? _cancel;

  /// Whether [update] is fully downloaded, else how many bytes are waiting to
  /// be resumed. Throws [Failure].
  Future<ApkLocalStatus> status(AppUpdateModel update) async {
    try {
      if (await _isComplete(update)) return (complete: true, receivedBytes: update.sizeBytes ?? 0);
      final part = await _partFile(update);
      return (complete: false, receivedBytes: await part.exists() ? await part.length() : 0);
    } on FileSystemException catch (e) {
      throw PlatformFailure('Could not read the update folder: $e');
    }
  }

  /// Downloads (or resumes) the APK, reporting `(received, total)` bytes;
  /// `total` is 0 when the server does not say. Returns true when the verified
  /// file is in place, false when [pause] stopped it. Throws [Failure].
  Future<bool> download(
    AppUpdateModel update, {
    required void Function(int receivedBytes, int totalBytes) onProgress,
  }) async {
    final token = _cancel = CancelToken();
    RandomAccessFile? out;
    try {
      if (await _isComplete(update)) return true;
      final part = await _partFile(update);
      await part.parent.create(recursive: true);
      var offset = await part.exists() ? await part.length() : 0;
      final expected = update.sizeBytes;
      if (expected != null && offset > expected) {
        await part.delete();
        offset = 0;
      }
      if (expected == null || offset < expected) {
        final response = await _api.openDownload(update.apkUrl, from: offset, cancelToken: token);
        // 200 instead of 206: the server ignored the range and sends everything.
        if (response.statusCode != 206) offset = 0;
        final length = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
        final total = expected ?? (length == null ? 0 : offset + length);
        out = await part.open(mode: offset > 0 ? FileMode.append : FileMode.write);
        var received = offset;
        onProgress(received, total);
        final sinceReport = Stopwatch()..start();
        await for (final chunk in response.data!.stream) {
          if (token.isCancelled) return false;
          await out.writeFrom(chunk);
          received += chunk.length;
          if (sinceReport.elapsed >= _progressEvery) {
            onProgress(received, total);
            sinceReport.reset();
          }
        }
        if (token.isCancelled) return false;
        await out.close();
        out = null;
        onProgress(received, total);
      }
      await _verify(part, update);
      await part.rename((await _apkFile(update)).path);
      return true;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || token.isCancelled) return false;
      // 416: our offset is past the file the server has now; start over next time.
      if (e.response?.statusCode == 416) await _discardPart(update);
      throw mapDioError(e);
    } on FileSystemException catch (e) {
      if (token.isCancelled) return false;
      throw PlatformFailure('Could not write the update: $e');
    } finally {
      try {
        await out?.close();
      } on FileSystemException {
        // Already closed or gone; nothing to save.
      }
      if (identical(_cancel, token)) _cancel = null;
    }
  }

  /// Stops the running [download]; the bytes received so far are kept.
  void pause() => _cancel?.cancel('paused');

  /// Hands the downloaded APK to Android's installer (which asks the user to
  /// allow installs from this app the first time). Throws [Failure].
  Future<void> install(AppUpdateModel update) async {
    final apk = await _apkFile(update);
    final OpenResult result;
    try {
      result = await OpenFilex.open(apk.path, type: apkMimeType);
    } catch (e) {
      throw PlatformFailure('Could not open the installer: $e');
    }
    switch (result.type) {
      case ResultType.done:
        return;
      case ResultType.noAppToOpen:
        throw const UnsupportedFailure('No installer on this device.');
      case ResultType.fileNotFound:
      case ResultType.permissionDenied:
      case ResultType.error:
        throw PlatformFailure('Could not open the installer: ${result.message}');
    }
  }

  /// Deletes every downloaded or partial APK except those of [keepVersionCode]
  /// (null: all of them). Never throws.
  Future<void> cleanUp({int? keepVersionCode}) async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return;
      final keep = keepVersionCode == null ? null : _name(keepVersionCode);
      await for (final entity in dir.list()) {
        final name = p.basename(entity.path);
        if (entity is File && name != keep && name != '$keep.part') await entity.delete();
      }
    } catch (e) {
      _logger.warn('Update clean-up failed: $e');
    }
  }

  Future<bool> _isComplete(AppUpdateModel update) async {
    final apk = await _apkFile(update);
    if (!await apk.exists()) return false;
    final expected = update.sizeBytes;
    if (expected == null || await apk.length() == expected) return true;
    // The server now describes a different file for this version.
    await apk.delete();
    return false;
  }

  /// Size, then SHA-256 (off the UI isolate). A bad file is deleted so the
  /// next attempt starts clean.
  Future<void> _verify(File part, AppUpdateModel update) async {
    final expectedSize = update.sizeBytes;
    final expectedHash = update.sha256;
    var ok = expectedSize == null || await part.length() == expectedSize;
    if (ok && expectedHash != null) {
      final path = part.path;
      final actual = await Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());
      ok = actual == expectedHash;
    }
    if (ok) return;
    await part.delete();
    _logger.warn('Update ${update.versionCode} failed verification; deleted.');
    throw const ServerFailure('The downloaded update does not match the published file.');
  }

  Future<void> _discardPart(AppUpdateModel update) async {
    try {
      final part = await _partFile(update);
      if (await part.exists()) await part.delete();
    } on FileSystemException {
      // Left in place; the size check on the next attempt handles it.
    }
  }

  Future<Directory> _dir() async => Directory(p.join((await _baseDirectory()).path, 'updates'));

  Future<File> _apkFile(AppUpdateModel update) async => File(p.join((await _dir()).path, _name(update.versionCode)));

  Future<File> _partFile(AppUpdateModel update) async => File('${(await _apkFile(update)).path}.part');

  static String _name(int versionCode) => 'dynaops-$versionCode.apk';
}
