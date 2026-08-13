import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_motion.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

class AppToggle extends StatelessWidget {
  const AppToggle({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.activeColor,
    this.label,
    this.semanticLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  /// Active-track tint. Defaults to the live (background-adaptive) brand accent.
  final Color? activeColor;

  /// Optional inline label rendered to the left of the switch.
  final String? label;

  /// Screen-reader name for the switch when no visible [label] is wanted —
  /// e.g. `AppToggleTile` passes its title so TalkBack doesn't announce a
  /// nameless "switch".
  final String? semanticLabel;

  static const double _trackW = 48;
  static const double _trackH = 28;
  static const double _thumb = 20;

  /// Gap between the track's rim and the thumb.
  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final live = enabled && onChanged != null;
    final glass = context.glass;
    final accent = activeColor ?? Theme.of(context).colorScheme.secondary;

    // One tween drives track fill, rim, glow, thumb offset and thumb colour, so
    // every part of the switch settles on the same fluid curve.
    Widget visual = TweenAnimationBuilder<double>(
      tween: Tween(begin: value ? 1 : 0, end: value ? 1 : 0),
      duration: AppDurations.fast,
      curve: AppCurves.fluid,
      builder: (context, t, _) => Container(
        width: _trackW,
        height: _trackH,
        padding: const EdgeInsets.all(_inset),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(glass.fillTop, accent.withValues(alpha: 0.90), t)!,
              Color.lerp(glass.fillBottom, accent.withValues(alpha: 0.70), t)!,
            ],
          ),
          border: Border.all(
            color: Color.lerp(glass.border, accent.withValues(alpha: 0.70), t)!,
          ),
          boxShadow: t == 0
              ? null
              : [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.35 * t),
                    blurRadius: 10,
                    spreadRadius: -1,
                  ),
                ],
        ),
        child: Align(
          alignment: Alignment(-1 + 2 * t, 0),
          child: Container(
            width: _thumb,
            height: _thumb,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Muted-foreground when off, white when on — legible against the
              // frosted track in both themes and against the accent fill.
              color: Color.lerp(glass.onGlassMuted, Colors.white, t),
              boxShadow: [
                BoxShadow(
                  color: glass.shadow,
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!live) visual = Opacity(opacity: 0.45, child: visual);

    final hasLabel = label != null;
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: AppPressable(
          onTap: () => _handle(!value),
          enabled: live,
          haptic: false, // selection click, not the default light impact
          pressedScale: hasLabel ? 0.98 : 0.92,
          semanticLabel: semanticLabel ?? label,
          minTapTarget: hasLabel ? null : AppSizes.minTapTargetSquare,
          child: hasLabel ? _row(context, visual) : visual,
        ),
      ),
    );
  }

  void _handle(bool v) {
    AppHaptics.selection();
    onChanged?.call(v);
  }

  Widget _row(BuildContext context, Widget toggle) => Row(
    children: [
      Expanded(
        child: Text(label!, style: Theme.of(context).textTheme.bodyLarge),
      ),
      const SizedBox(width: AppSpacing.sm),
      toggle,
    ],
  );
}
