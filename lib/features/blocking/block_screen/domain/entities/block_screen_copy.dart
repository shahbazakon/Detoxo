import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';

/// One action button on the wall, in display order.
class BlockScreenButton {
  const BlockScreenButton(
    this.label,
    this.action, {
    this.primary = false,
    this.ghost = false,
    this.locked = false,
  });

  final String label;

  /// `GO_HOME` | `OPEN_APP` | `DISMISS` | `UNBLOCK` — the `blockScreenAction` token.
  final String action;
  final bool primary;
  final bool ghost;

  /// Disabled while its countdown runs (EVO-025) — drawn dimmed.
  final bool locked;
}

/// MIRROR CONTRACT: every string here reproduces the native wall's copy
/// (`res/values/strings.xml` + `WallCopy` in `overlay/BlockScreenRenderer.kt`),
/// so the Flutter preview reads exactly like the real thing. Edit the Kotlin
/// and the resources first, then mirror here — `block_screen_test.dart` pins
/// the plan labels and that the wire token `curious` never surfaces.
class BlockScreenCopy {
  const BlockScreenCopy({
    required this.chip,
    required this.headline,
    required this.reason,
    required this.stats,
    required this.buttons,
  });

  factory BlockScreenCopy.from(BlockScreenPayload p, BlockScreenStyle style) {
    final name = p.displayName.isEmpty ? 'This app' : p.displayName;
    final headline = p.isAdult
        ? 'Adult site blocked by Detoxo'
        : '$name is blocked by Detoxo';
    final reason = switch (p.blockReason) {
      BlockReason.plan => switch (p.plan) {
        BlockingPlan.curious => 'Your Conscious time bank is empty',
        BlockingPlan.oneReel =>
          p.allowance <= 1
              ? 'You’ve watched your reel'
              : 'You’ve watched your ${p.allowance} reels',
        _ => 'Block All is on',
      },
      BlockReason.appBlock => 'Locked in your App blocker',
      BlockReason.webRule => 'On your website blocklist',
      BlockReason.adult => 'Adult content (18+)',
      BlockReason.dailyLimit => 'Your daily limit is used up',
      BlockReason.schedule => 'Blocked by a schedule',
    };
    final stats = <String>[
      if (style.showCount &&
          p.todayCount >= 0 &&
          p.referenceType == BlockReferenceType.reel)
        _plural(p.todayCount, 'reel today', 'reels today'),
      if (p.bankMs >= 0)
        '${_mmss(p.bankMs)} left in your bank'
      else if (p.allowanceLeft >= 0)
        _plural(p.allowanceLeft, 'reel left', 'reels left'),
      if (style.showOpens && p.opensToday >= 0 && p.appLabel.isNotEmpty)
        '${p.appLabel} opened ${_plural(p.opensToday, 'time today', 'times today')}',
    ];
    final isApp = p.referenceType == BlockReferenceType.app;
    final backTo = p.appLabel.isNotEmpty
        ? p.appLabel
        : p.displayName.isNotEmpty
        ? p.displayName
        : 'This app';
    // The ghost exit counts down before it unlocks (EVO-025): the preview
    // shows it as the wall first appears, "Back to Instagram · 5", dimmed.
    final delay = style.backDelaySec;
    final buttons = <BlockScreenButton>[
      if (isApp)
        const BlockScreenButton('Got it', 'DISMISS', primary: true)
      else
        const BlockScreenButton('Go home', 'GO_HOME', primary: true),
      if (p.offersOpenApp) const BlockScreenButton('Open Detoxo', 'OPEN_APP'),
      if (!isApp)
        BlockScreenButton(
          delay > 0 ? 'Back to $backTo · $delay' : 'Back to $backTo',
          'DISMISS',
          ghost: true,
          locked: delay > 0,
        ),
      if (p.offersUnblock)
        const BlockScreenButton('Allow for a while', 'UNBLOCK', ghost: true),
    ];
    return BlockScreenCopy(
      chip: planLabel(p.plan, allowance: p.allowance),
      headline: headline,
      reason: reason,
      stats: stats,
      buttons: buttons,
    );
  }

  final String chip;
  final String headline;
  final String reason;
  final List<String> stats;
  final List<BlockScreenButton> buttons;

  /// Everything a screen reader would say, in reading order.
  String get semanticsLabel => [
    chip,
    headline,
    reason,
    ...stats,
    ...buttons.map((b) => b.label),
  ].where((s) => s.isNotEmpty).join('. ');

  static String _plural(int n, String one, String other) =>
      '$n ${n == 1 ? one : other}';

  static String _mmss(int ms) {
    final total = ms ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}
