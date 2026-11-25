/// `AppUpdateModel`: one answer of the update endpoint — the newer build's
/// `versionCode` / `versionName`, where its APK is (`apkUrl`), how to check the
/// download (`sha256`, `sizeBytes`), the release notes per language, and the
/// two switches the server controls: `mandatory` (the app may not be used
/// until it is installed) and `showAlert` (false hides the update entirely).
///
/// Why it exists: the typed form of the endpoint's JSON; it is also what is
/// stored so a mandatory update still blocks the app offline.
/// Status: used — parsed and stored by `AppUpdateRepository`, carried by every
/// `AppUpdateState`.
library;

import 'package:equatable/equatable.dart';

class AppUpdateModel extends Equatable {
  const AppUpdateModel({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.mandatory = false,
    this.showAlert = true,
    this.sha256,
    this.sizeBytes,
    this.notes = const {},
  });

  /// Throws [FormatException] when a required field is missing or malformed.
  factory AppUpdateModel.fromJson(Map<String, dynamic> json) {
    final versionCode = _int(json['versionCode']);
    final apkUrl = json['apkUrl'];
    if (versionCode == null) throw const FormatException('versionCode missing');
    if (apkUrl is! String || !apkUrl.startsWith('https://')) {
      throw const FormatException('apkUrl missing or not https');
    }
    final sha256 = json['sha256'];
    return AppUpdateModel(
      versionCode: versionCode,
      versionName: json['versionName']?.toString() ?? '$versionCode',
      apkUrl: apkUrl,
      mandatory: json['mandatory'] == true,
      // Absent means "show": only an explicit false hides the update.
      showAlert: json['showAlert'] != false,
      sha256: sha256 is String && sha256.isNotEmpty ? sha256.toLowerCase() : null,
      sizeBytes: _int(json['sizeBytes']),
      notes: _notes(json['notes']),
    );
  }

  /// Android `versionCode` of the newer build.
  final int versionCode;
  final String versionName;
  final String apkUrl;

  /// The app may not be used until this build is installed.
  final bool mandatory;

  /// False: the server does not want this update shown at all.
  final bool showAlert;

  /// Lower-case hex SHA-256 of the APK; null when the server sends none.
  final String? sha256;
  final int? sizeBytes;

  /// Release notes by language code (`en`, `ar`); may be empty.
  final Map<String, String> notes;

  /// The notes in [languageCode], else English, else none.
  String? notesFor(String languageCode) => notes[languageCode] ?? notes['en'];

  Map<String, dynamic> toJson() => {
        'versionCode': versionCode,
        'versionName': versionName,
        'apkUrl': apkUrl,
        'mandatory': mandatory,
        'showAlert': showAlert,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'notes': notes,
      };

  @override
  List<Object?> get props => [versionCode, versionName, apkUrl, mandatory, showAlert, sha256, sizeBytes, notes];

  static int? _int(Object? value) => switch (value) {
        final int v => v,
        final num v => v.toInt(),
        final String v => int.tryParse(v),
        _ => null,
      };

  /// Accepts `{"en": "...", "ar": "..."}` or one plain string (kept as English).
  static Map<String, String> _notes(Object? value) => switch (value) {
        final String v when v.isNotEmpty => {'en': v},
        final Map<dynamic, dynamic> v => {
            for (final entry in v.entries)
              if (entry.value is String && (entry.value as String).isNotEmpty) '${entry.key}': entry.value as String,
          },
        _ => const {},
      };
}
