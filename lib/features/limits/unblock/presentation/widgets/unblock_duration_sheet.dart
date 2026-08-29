import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_config.dart';
import 'package:flutter/material.dart';

/// "Allow {thing} for…" — the 5 / 15 / 30 / 60-minute chips.
///
/// One sheet for every target (a website row, an app row, the block-screen
/// wall, an override on a locked rule). It started as the web blocker's
/// per-site pause sheet in EVO-012 and is lifted here verbatim: a second
/// duration vocabulary would be a second thing to learn for no gain.
///
/// Returns the chosen window, or null when the user backed out — and backing
/// out grants nothing, which is the whole contract of a friction gate.
Future<Duration?> showUnblockDurationSheet(
  BuildContext context, {
  required String label,

  /// Caps the offered chips, so an override cannot buy more than
  /// `BypassConfig.overrideMaxWindowMs`.
  Duration? maxWindow,

  /// EVO-053: allowances left in the current period, or null when they are not
  /// rationed. Shown BEFORE the choice, not as a refusal after it — a budget
  /// the user only learns about by hitting it is a trap, not a budget.
  int? remaining,
}) async {
  final limit = maxWindow?.inMinutes ?? unblockDurationMinutes.last;
  final options = [
    for (final m in unblockDurationMinutes)
      if (m <= limit) m,
  ];
  // A pathologically small cap must still offer something rather than an empty
  // sheet the user cannot act on.
  final chips = options.isEmpty ? [unblockDurationMinutes.first] : options;
  final minutes = await GlassBottomSheet.show<int>(
    context: context,
    title: 'Allow $label for…',
    child: Builder(
      builder: (sheetContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final m in chips)
                AppChip(
                  label: '$m min',
                  selected: false,
                  // Picking one closes the sheet, so there is no selected state
                  // to announce — without this TalkBack says "5 min, not
                  // selected".
                  momentary: true,
                  onSelected: () => Navigator.of(sheetContext).pop(m),
                ),
            ],
          ),
          if (remaining != null) ...[
            const SizedBox(height: AppSpacing.sm),
            InlineHint(
              icon: Icons.timer_outlined,
              text: remaining == 1
                  ? '1 allowance left in this period.'
                  : '$remaining allowances left in this period.',
            ),
          ],
        ],
      ),
    ),
  );
  return minutes == null ? null : Duration(minutes: minutes);
}
