/// `AppUpdateApi`: the two raw calls of the self-hosted updater —
/// `GET AppUpdate/check?platform=android&versionCode=N` (works before login)
/// and a streamed, resumable `GET` of the APK (`Range: bytes=N-`). Neither
/// carries the session token: the check is anonymous and the APK may live on
/// another host.
///
/// Why it exists: API-client layer of the update feature; the repositories
/// parse, store and map errors.
/// Status: used — by `AppUpdateRepository` and `ApkDownloadRepository`.
library;

import 'package:dio/dio.dart';

import '../../../core/network/dio_client.dart';

class AppUpdateApi {
  AppUpdateApi(this._dio);
  final Dio _dio;

  /// Relative to `AppConfig.apiBaseUrl`. Change here if the backend names it differently.
  static const checkPath = 'AppUpdate/check';

  static const _anonymous = {AuthInterceptor.skipAuthKey: true};

  /// The endpoint's answer (the envelope's `data` when there is one).
  /// Throws [DioException] / [FormatException]; the repository maps them.
  Future<Map<String, dynamic>> check({required String platform, required int versionCode}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      checkPath,
      queryParameters: {'platform': platform, 'versionCode': versionCode},
      options: Options(extra: _anonymous),
    );
    final body = response.data;
    if (body == null) throw const FormatException('Update check returned no body');
    final data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }

  /// Opens the APK as a byte stream starting at byte [from]. A server that
  /// honours the range answers 206; one that ignores it answers 200 with the
  /// whole file. Throws [DioException].
  Future<Response<ResponseBody>> openDownload(
    String url, {
    required int from,
    required CancelToken cancelToken,
  }) =>
      _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          // Between two chunks, not for the whole file.
          receiveTimeout: const Duration(seconds: 30),
          headers: {if (from > 0) 'Range': 'bytes=$from-'},
          extra: _anonymous,
        ),
      );
}
