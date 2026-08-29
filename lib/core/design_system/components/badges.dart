import 'package:detoxo/core/design_system/tokens/app_colors.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// Semantic tone shared by pills, badges and toasts.
enum AppTone { neutral, accent, success, warning, danger }

/// Resolves a tone to its accent colour (context needed for `neutral`).
Color toneColor(BuildContext context, AppTone tone) => switch (tone) {
  AppTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
  AppTone.accent => Theme.of(context).colorScheme.secondary,
  AppTone.success => AppColors.success,
  AppTone.warning => AppColors.warning,
  AppTone.danger => AppColors.danger,
};

/// Text colour to use ON a [toneColor] fill. The tone is a *surface* accent:
/// painted as 11 sp label text over the pill's 16 %-alpha fill it lands around
/// 2:1 (`warning`) and 3.2:1 (`success`) in light theme, both under WCAG AA.
/// Dark theme already clears AA comfortably, so only light is darkened — to a
/// fixed lightness ceiling, which holds for any hue.
Color onToneColor(BuildContext context, AppTone tone) {
  final color = toneColor(context, tone);
  if (Theme.of(context).brightness == Brightness.dark) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl.lightness <= _maxOnToneLightness
      ? color
      : hsl.withLightness(_maxOnToneLightness).toColor();
}

const double _maxOnToneLightness = 0.32;

/// A small rounded status chip — "Required", "Premium", "Active". Replaces the
/// ad-hoc inline chips that were scattered across screens.
class Pill extends StatelessWidget {
  const Pill({
    required this.label,
    this.tone = AppTone.neutral,
    this.icon,
    super.key,
  });

  final String label;
  final AppTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(context, tone);
    final onTone = onToneColor(context, tone);
    return Container(
      // A pill lives in trailing slots that are NOT flex children (see
      // GlassListTile — making one squeezes the title's Expanded instead), so
      // it has to bound itself: a long label ("Needs usage access") at large
      // system font scale otherwise overflows the row it sits in. Ellipsis
      // beats overflow, and no status chip is legitimately this wide.
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.4,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: onTone),
            const SizedBox(width: 4),
          ],
          // Flexible + ellipsis: a pill is a trailing slot, and a long label
          // ("Needs usage access") must give way rather than overflow the row.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: onTone,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tiny label/dot marker (e.g. a stat trend). Named to avoid clashing with
/// Material's own `Badge`.
class AppBadge extends StatelessWidget {
  const AppBadge.label(this.label, {this.tone = AppTone.neutral, super.key});

  final String label;
  final AppTone tone;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: AppRadius.brSm,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
