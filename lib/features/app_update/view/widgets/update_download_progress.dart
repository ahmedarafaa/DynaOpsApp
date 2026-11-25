/// `UpdateDownloadProgress`: the progress bar of the update download with a
/// caption under it (megabytes so far, "paused", or the error), coloured as an
/// error when the download failed. Strings arrive already localised.
///
/// Why it exists: keeps `AppUpdateScreen.build` small; it is specific to this
/// feature, so it stays in `view/widgets/` (flutter-build-shared-widgets).
/// Status: used — by `AppUpdateScreen`.
library;

import 'package:flutter/material.dart';

class UpdateDownloadProgress extends StatelessWidget {
  const UpdateDownloadProgress({
    super.key,
    required this.fraction,
    required this.sizeLabel,
    this.message,
    this.isError = false,
  });

  /// 0..1; negative shows an indeterminate bar (size unknown).
  final double fraction;

  /// E.g. "12.3 of 48.0 MB".
  final String sizeLabel;

  /// Shown under the size: "Download paused" or what went wrong.
  final String? message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = fraction < 0 ? null : '${(fraction * 100).floor()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: fraction < 0 ? null : fraction,
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
          color: isError ? theme.colorScheme.error : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(sizeLabel, style: theme.textTheme.bodySmall)),
            if (percent != null) Text(percent, style: theme.textTheme.bodySmall),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(
            message!,
            style: theme.textTheme.bodyMedium?.copyWith(color: isError ? theme.colorScheme.error : null),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
