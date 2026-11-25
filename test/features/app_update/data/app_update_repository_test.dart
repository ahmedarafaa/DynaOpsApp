/// Tests for `AppUpdateRepository`: an answer newer than the installed build
/// is pending and stored; `showAlert: false`, a version already installed and
/// `updateAvailable: false` are not pending; a failed check keeps the stored
/// answer (a mandatory update still blocks offline); `changes` fires after
/// every check; downloads of other versions are cleaned up; nothing happens
/// off Android.
///
/// Status: active — part of `flutter test`.
library;

import 'package:dio/dio.dart';
import 'package:dynaopsapp/core/logging/app_logger.dart';
import 'package:dynaopsapp/core/storage/prefs_store.dart';
import 'package:dynaopsapp/features/app_update/data/apk_download_repository.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_api.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockApi extends Mock implements AppUpdateApi {}

class _MockDownloads extends Mock implements ApkDownloadRepository {}

class _MockLogger extends Mock implements AppLogger {}

Map<String, dynamic> answer({int versionCode = 12, bool mandatory = false, bool? showAlert}) => {
      'updateAvailable': true,
      'mandatory': mandatory,
      'showAlert': ?showAlert,
      'versionCode': versionCode,
      'versionName': '1.3.0',
      'apkUrl': 'https://files.example.com/dynaops-1.3.0.apk',
      'sha256': 'ABCDEF',
      'sizeBytes': 100,
      'notes': {'en': 'Faster', 'ar': 'أسرع'},
    };

void main() {
  late _MockApi api;
  late _MockDownloads downloads;
  late PrefsStore prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = PrefsStore(await SharedPreferences.getInstance());
    api = _MockApi();
    downloads = _MockDownloads();
    when(() => downloads.cleanUp(keepVersionCode: any(named: 'keepVersionCode'))).thenAnswer((_) async {});
  });

  Future<AppUpdateRepository> build({int installed = 10, bool supported = true}) async {
    final repository = AppUpdateRepository(
      api,
      prefs,
      downloads,
      _MockLogger(),
      installedVersionCode: () async => installed,
      supported: supported,
    );
    await repository.load();
    return repository;
  }

  void serverAnswers(Map<String, dynamic> json) => when(
        () => api.check(platform: any(named: 'platform'), versionCode: any(named: 'versionCode')),
      ).thenAnswer((_) async => json);

  void serverFails() => when(
        () => api.check(platform: any(named: 'platform'), versionCode: any(named: 'versionCode')),
      ).thenThrow(DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionError));

  test('a newer build is pending, sent the installed version, and parsed', () async {
    serverAnswers(answer(mandatory: true));
    final repository = await build();

    final pending = await repository.check();

    verify(() => api.check(platform: 'android', versionCode: 10)).called(1);
    expect(pending, isNotNull);
    expect(pending!.versionCode, 12);
    expect(pending.mandatory, true);
    expect(pending.showAlert, true);
    expect(pending.sha256, 'abcdef');
    expect(pending.notesFor('ar'), 'أسرع');
    expect(pending.notesFor('fr'), 'Faster');
    expect(repository.pending, pending);
  });

  test('showAlert false hides the update, even a mandatory one', () async {
    serverAnswers(answer(mandatory: true, showAlert: false));
    final repository = await build();

    expect(await repository.check(), isNull);
  });

  test('a version that is not newer than the installed one is not pending', () async {
    serverAnswers(answer(versionCode: 10));
    final repository = await build();

    expect(await repository.check(), isNull);
  });

  test('a failed check keeps the stored mandatory update (offline)', () async {
    serverAnswers(answer(mandatory: true));
    await (await build()).check();

    serverFails();
    final relaunched = await build();

    expect(relaunched.pending?.mandatory, true);
    expect((await relaunched.check())?.versionCode, 12);
  });

  test('the stored update stops applying once that build is installed', () async {
    serverAnswers(answer(mandatory: true));
    await (await build()).check();

    expect((await build(installed: 12)).pending, isNull);
  });

  test('updateAvailable false clears the stored update', () async {
    serverAnswers(answer());
    final repository = await build();
    await repository.check();

    serverAnswers({'updateAvailable': false});
    expect(await repository.check(), isNull);
    expect((await build()).pending, isNull);
  });

  test('a malformed answer keeps the previous one', () async {
    serverAnswers(answer());
    final repository = await build();
    await repository.check();

    serverAnswers({'updateAvailable': true, 'versionCode': 13, 'apkUrl': 'http://insecure.example.com/a.apk'});
    expect((await repository.check())?.versionCode, 12);
  });

  test('changes fires after every check, and other versions are cleaned up', () async {
    serverAnswers(answer());
    final repository = await build();
    final announced = expectLater(repository.changes, emitsInOrder([isNotNull, isNotNull]));

    await repository.check();
    await repository.check();

    await announced;
    verify(() => downloads.cleanUp(keepVersionCode: 12)).called(2);
  });

  test('off Android nothing is checked', () async {
    final repository = await build(supported: false);

    expect(await repository.check(), isNull);
    verifyNever(() => api.check(platform: any(named: 'platform'), versionCode: any(named: 'versionCode')));
  });
}
