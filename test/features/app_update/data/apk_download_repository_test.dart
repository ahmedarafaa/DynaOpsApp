/// Tests for `ApkDownloadRepository` against real files in a temp folder and a
/// faked byte stream: a download is verified and renamed; a partial file is
/// resumed from its length (and restarted when the server ignores the range);
/// a finished file is never downloaded again; a wrong hash deletes the file;
/// a network error keeps the bytes; `pause` stops and keeps them; `cleanUp`
/// removes other versions.
///
/// Status: active — part of `flutter test`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dynaopsapp/core/logging/app_logger.dart';
import 'package:dynaopsapp/core/network/failure.dart';
import 'package:dynaopsapp/features/app_update/data/apk_download_repository.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_api.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

class _MockApi extends Mock implements AppUpdateApi {}

class _MockLogger extends Mock implements AppLogger {}

final content = Uint8List.fromList(List.generate(1000, (i) => i % 251));

AppUpdateModel update({int versionCode = 12, String? hash, int? size = 1000}) => AppUpdateModel(
      versionCode: versionCode,
      versionName: '1.3.0',
      apkUrl: 'https://files.example.com/app.apk',
      sha256: hash ?? sha256.convert(content).toString(),
      sizeBytes: size,
    );

Response<ResponseBody> response(Stream<Uint8List> stream, {int status = 200, int? length}) => Response(
      requestOptions: RequestOptions(),
      statusCode: status,
      headers: Headers.fromMap({
        if (length != null) Headers.contentLengthHeader: ['$length'],
      }),
      data: ResponseBody(stream, status),
    );

void main() {
  late Directory base;
  late _MockApi api;
  late ApkDownloadRepository repository;
  late File apk;
  late File part;

  setUpAll(() => registerFallbackValue(CancelToken()));

  setUp(() async {
    base = await Directory.systemTemp.createTemp('apk_download_test');
    api = _MockApi();
    repository = ApkDownloadRepository(api, _MockLogger(), baseDirectory: () async => base);
    apk = File(p.join(base.path, 'updates', 'dynaops-12.apk'));
    part = File('${apk.path}.part');
  });

  tearDown(() => base.delete(recursive: true));

  /// The server sends [content] from the requested offset in two chunks.
  void serverSends({bool honoursRange = true}) {
    when(() => api.openDownload(any(), from: any(named: 'from'), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((invocation) async {
      final from = honoursRange ? invocation.namedArguments[#from] as int : 0;
      final rest = content.sublist(from);
      final half = rest.length ~/ 2;
      return response(
        Stream.fromIterable([rest.sublist(0, half), rest.sublist(half)]),
        status: from > 0 ? 206 : 200,
        length: rest.length,
      );
    });
  }

  test('downloads, verifies and renames; progress ends at the full size', () async {
    serverSends();
    final progress = <(int, int)>[];

    final finished = await repository.download(update(), onProgress: (r, t) => progress.add((r, t)));

    expect(finished, true);
    expect(await apk.readAsBytes(), content);
    expect(await part.exists(), false);
    expect(progress.first, (0, 1000));
    expect(progress.last, (1000, 1000));
    expect(await repository.status(update()), (complete: true, receivedBytes: 1000));
  });

  test('resumes a partial file from its length', () async {
    serverSends();
    await part.create(recursive: true);
    await part.writeAsBytes(content.sublist(0, 400));
    expect(await repository.status(update()), (complete: false, receivedBytes: 400));

    final finished = await repository.download(update(), onProgress: (_, _) {});

    expect(finished, true);
    verify(() => api.openDownload(any(), from: 400, cancelToken: any(named: 'cancelToken'))).called(1);
    expect(await apk.readAsBytes(), content);
  });

  test('starts over when the server ignores the range', () async {
    serverSends(honoursRange: false);
    await part.create(recursive: true);
    await part.writeAsBytes(content.sublist(0, 400));

    expect(await repository.download(update(), onProgress: (_, _) {}), true);
    expect(await apk.readAsBytes(), content);
  });

  test('a finished file is not downloaded again', () async {
    await apk.create(recursive: true);
    await apk.writeAsBytes(content);

    expect(await repository.download(update(), onProgress: (_, _) {}), true);
    verifyNever(() => api.openDownload(any(), from: any(named: 'from'), cancelToken: any(named: 'cancelToken')));
  });

  test('a file that fails the hash check is deleted and reported', () async {
    serverSends();

    await expectLater(
      repository.download(update(hash: 'not-the-hash'), onProgress: (_, _) {}),
      throwsA(isA<ServerFailure>()),
    );
    expect(await part.exists(), false);
    expect(await apk.exists(), false);
  });

  test('a network error keeps the bytes received so far', () async {
    when(() => api.openDownload(any(), from: any(named: 'from'), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async {
      Stream<Uint8List> broken() async* {
        yield content.sublist(0, 300);
        throw DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionError);
      }

      return response(broken(), length: 1000);
    });

    await expectLater(
      repository.download(update(), onProgress: (_, _) {}),
      throwsA(isA<NetworkFailure>()),
    );
    expect(await repository.status(update()), (complete: false, receivedBytes: 300));
  });

  test('pause stops the download and keeps the bytes', () async {
    final chunks = StreamController<Uint8List>();
    when(() => api.openDownload(any(), from: any(named: 'from'), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => response(chunks.stream, length: 1000));
    final firstChunkWritten = Completer<void>();

    final download = repository.download(
      update(),
      onProgress: (received, _) {
        if (received == 0) chunks.add(content.sublist(0, 300));
      },
    );
    // The first chunk is on disk once the loop asks for the next one.
    chunks.onListen = () => Future<void>.delayed(const Duration(milliseconds: 200), firstChunkWritten.complete);
    await firstChunkWritten.future;
    repository.pause();
    chunks.add(content.sublist(300, 600));

    expect(await download, false);
    expect((await repository.status(update())).receivedBytes, 300);
    await chunks.close();
  });

  test('cleanUp removes every other version', () async {
    final old = File(p.join(base.path, 'updates', 'dynaops-11.apk'));
    await old.create(recursive: true);
    await part.create();
    await apk.create();

    await repository.cleanUp(keepVersionCode: 12);
    expect(await old.exists(), false);
    expect(await part.exists(), true);
    expect(await apk.exists(), true);

    await repository.cleanUp();
    expect(await part.exists(), false);
    expect(await apk.exists(), false);
  });
}
