/// Tests for `UpdateGate`: a mandatory update redirects every route but the
/// support tools to `/update`; an optional one never redirects and is offered
/// once per version; `/update` with nothing pending goes back to the shell;
/// every check notifies the router.
///
/// Status: active — part of `flutter test`.
library;

import 'dart:async';

import 'package:dynaopsapp/core/router/update_gate.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_model.dart';
import 'package:dynaopsapp/features/app_update/data/app_update_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockUpdates extends Mock implements AppUpdateRepository {}

AppUpdateModel update({bool mandatory = false, int versionCode = 12}) => AppUpdateModel(
      versionCode: versionCode,
      versionName: '1.3.0',
      apkUrl: 'https://files.example.com/app.apk',
      mandatory: mandatory,
    );

void main() {
  late _MockUpdates updates;
  late StreamController<AppUpdateModel?> changes;
  late UpdateGate gate;

  setUp(() {
    updates = _MockUpdates();
    changes = StreamController.broadcast();
    when(() => updates.changes).thenAnswer((_) => changes.stream);
    when(() => updates.pending).thenReturn(null);
    gate = UpdateGate(updates);
  });

  tearDown(() {
    gate.dispose();
    changes.close();
  });

  test('nothing pending: no redirect, and /update goes back to the shell', () {
    expect(gate.redirect('/'), isNull);
    expect(gate.redirect('/update'), '/');
    expect(gate.takeOptionalOffer(), false);
  });

  test('a mandatory update redirects everything but the support tools', () {
    when(() => updates.pending).thenReturn(update(mandatory: true));

    expect(gate.redirect('/'), '/update');
    expect(gate.redirect('/permissions'), '/update');
    expect(gate.redirect('/update'), isNull);
    expect(gate.redirect('/diagnostics'), isNull);
    expect(gate.takeOptionalOffer(), false);
  });

  test('an optional update never redirects and is offered once per version', () {
    when(() => updates.pending).thenReturn(update());

    expect(gate.redirect('/'), isNull);
    expect(gate.redirect('/update'), isNull);
    expect(gate.takeOptionalOffer(), true);
    expect(gate.takeOptionalOffer(), false);

    when(() => updates.pending).thenReturn(update(versionCode: 13));
    expect(gate.takeOptionalOffer(), true);
  });

  test('every check notifies the router', () async {
    var notified = 0;
    gate.addListener(() => notified++);

    changes.add(null);
    await Future<void>.delayed(Duration.zero);

    expect(notified, 1);
  });
}
