/// `AppUpdateRepository`: asks the update endpoint whether a newer build
/// exists for the installed `versionCode`, stores the answer, and exposes the
/// one that still applies as [pending]. The stored answer is what keeps a
/// mandatory update blocking the app when the next check fails (offline). An
/// answer with `showAlert: false`, or for a version already installed, is not
/// pending. [changes] fires after every check. Downloads that no longer match
/// the pending version are deleted.
///
/// Why it exists: the app is sent to users directly (no Play Store), so it
/// finds its own updates; the check runs before login, on launch and on every
/// return to the foreground.
/// Status: used — checked from `app.dart`, read by `UpdateGate` and
/// `AppUpdateCubit`; tested in
/// `test/features/app_update/data/app_update_repository_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/network/failure.dart';
import '../../../core/storage/prefs_store.dart';
import 'apk_download_repository.dart';
import 'app_update_api.dart';
import 'app_update_model.dart';

class AppUpdateRepository {
  AppUpdateRepository(
    this._api,
    this._prefs,
    this._downloads,
    this._logger, {
    Future<int> Function()? installedVersionCode,
    bool? supported,
  })  : _installedVersionCode = installedVersionCode ?? _readInstalledVersionCode,
        _supported = supported ?? Platform.isAndroid;

  static const _storageKey = 'app_update.latest';

  final AppUpdateApi _api;
  final PrefsStore _prefs;
  final ApkDownloadRepository _downloads;
  final AppLogger _logger;
  final Future<int> Function() _installedVersionCode;

  /// Self-update installs an APK, so it exists on Android only.
  final bool _supported;

  final _changes = StreamController<AppUpdateModel?>.broadcast();
  int _installed = 0;
  AppUpdateModel? _latest;
  Future<AppUpdateModel?>? _running;

  /// [pending] after every [check], changed or not.
  Stream<AppUpdateModel?> get changes => _changes.stream;

  /// The update to show: newer than the installed build and not hidden by the
  /// server. Null when there is nothing to show.
  AppUpdateModel? get pending {
    final latest = _latest;
    if (latest == null || !latest.showAlert || latest.versionCode <= _installed) return null;
    return latest;
  }

  /// Reads the installed version and the stored answer. Call once before use.
  /// Never throws.
  Future<void> load() async {
    if (!_supported) return;
    try {
      _installed = await _installedVersionCode();
      final raw = _prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        _latest = AppUpdateModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (e) {
      _logger.warn('Ignoring stored update answer: $e');
    }
    await _downloads.cleanUp(keepVersionCode: pending?.versionCode);
  }

  /// Asks the server and returns [pending]. A failed check keeps the stored
  /// answer. Never throws; overlapping calls share one request.
  Future<AppUpdateModel?> check() {
    if (!_supported) return Future.value();
    return _running ??= _check().whenComplete(() => _running = null);
  }

  Future<AppUpdateModel?> _check() async {
    try {
      final json = await _api.check(versionCode: _installed);
      _latest = json['updateAvailable'] == false ? null : AppUpdateModel.fromJson(json);
      await _prefs.setString(_storageKey, _latest == null ? '' : jsonEncode(_latest!.toJson()));
      await _downloads.cleanUp(keepVersionCode: pending?.versionCode);
    } on DioException catch (e) {
      _logger.warn('Update check failed: ${mapDioError(e).message}');
    } on FormatException catch (e) {
      _logger.warn('Unexpected update answer: ${e.message}');
    }
    _changes.add(pending);
    return pending;
  }

  static Future<int> _readInstalledVersionCode() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
}
