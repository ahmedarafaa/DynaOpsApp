/// `UpdateGate`: the router's guard for app updates. While a **mandatory**
/// update is pending every route redirects to `/update` (diagnostics and the
/// request inspector stay reachable for support), so the app cannot be used
/// until the new build is installed — including before login and offline,
/// because the pending update comes from the stored answer. An **optional**
/// update is never forced: [takeOptionalOffer] says once per version and per
/// run that the screen should be pushed over whatever is open, so "Later"
/// really dismisses it and the web app underneath keeps its state.
///
/// Why it exists: a router `redirect` enforces the mandatory rule in one
/// place, the same way `PermissionGate` does for permissions.
/// Status: used — `redirect` and `refreshListenable` of `createAppRouter`,
/// and `app.dart` for the optional offer; tested in
/// `test/core/router/update_gate_test.dart`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/app_update/data/app_update_model.dart';
import '../../features/app_update/data/app_update_repository.dart';

class UpdateGate extends ChangeNotifier {
  UpdateGate(this._updates) {
    _subscription = _updates.changes.listen((_) => notifyListeners());
  }

  static const updatePath = '/update';

  /// Reachable during a mandatory update: support tools only.
  static const openPaths = {'/diagnostics', '/requests'};

  final AppUpdateRepository _updates;
  late final StreamSubscription<AppUpdateModel?> _subscription;
  int? _offeredVersionCode;

  /// `/update` while a mandatory update is pending; `/` to leave an update
  /// screen that has nothing to show; else null.
  String? redirect(String path) {
    final pending = _updates.pending;
    if (path == updatePath) return pending == null ? '/' : null;
    if (pending != null && pending.mandatory && !openPaths.contains(path)) return updatePath;
    return null;
  }

  /// True the first time an optional update is pending in this run (and again
  /// for a newer one): the caller then opens `/update` on top.
  bool takeOptionalOffer() {
    final pending = _updates.pending;
    if (pending == null || pending.mandatory || pending.versionCode == _offeredVersionCode) return false;
    _offeredVersionCode = pending.versionCode;
    return true;
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
