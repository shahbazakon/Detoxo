import 'package:detoxo/core/design_system/components/badges.dart';
import 'package:detoxo/core/design_system/foundations/glass_container.dart';
import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_colors.dart';
import 'package:detoxo/core/design_system/tokens/app_motion.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:detoxo/core/widgets/common_widgets.dart' show SectionCard;
import 'package:flutter/material.dart';

/// A frosted, optionally tappable surface. Use for hero/status cards and any
/// standalone glass panel. For titled sections use [SectionCard] (common_widgets).
class GlassCard extends StatelessWidget {
  const GlassCard({
    required this.child,
    this.onTap,
    this.padding = AppInsets.card,
    this.accent,
    this.blurSigma,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// Tints the glass fill/border (e.g. status card uses [AppColors.accent]).
  final Color? accent;
  final double? blurSigma;

  @override
  Widget build(BuildContext context) {
    final card = GlassContainer(
      padding: padding,
      blurSigma: blurSigma ?? 16,
      tintTop: accent?.withValues(alpha: 0.20),
      tintBottom: accent?.withValues(alpha: 0.06),
      borderColor: accent?.withValues(alpha: 0.40),
      child: child,
    );
    if (onTap == null) return card;
    return AppPressable(onTap: onTap!, child: card);
  }
}

/// Optional trend marker for a [StatCard].
class TrendDelta {
  const TrendDelta(this.percent, {this.up = true});
  final int percent;
  final bool up;
}

/// A metric tile that animates its value (count-up) when it changes — making a
/// live refresh visible. Sits in a `Row` (caller wraps in `Expanded`); uses a
/// flat translucent glass (cheap, no per-frame saveLayer).
class StatCard extends StatelessWidget {
  const StatCard({
    required this.label,
    required this.value,
    required this.icon,
    this.unit,
    this.trend,
    super.key,
  });

  final String label;
  final int value;
  final IconData icon;
  final String? unit;
  final TrendDelta? trend;

  /// What a screen reader hears: one sentence, not the three loose nodes the
  /// visual layout happens to produce.
  String _semanticLabel() {
    final trailing = trend == null
        ? ''
        : ', ${trend!.up ? 'up' : 'down'} ${trend!.percent} percent';
    return '$label: $value${unit == null ? '' : ' $unit'}$trailing';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // The count-up is decoration. Honour the OS "remove animations" setting,
    // and keep the per-frame tween churn out of the semantics tree entirely —
    // otherwise TalkBack reads every intermediate number (the
    // `ReelCounterCard` rule).
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: _semanticLabel(),
      excludeSemantics: true,
      child: GlassContainer(
        enableBlur: false,
        padding: const EdgeInsets.all(14),
        tintTop: AppColors.seed.withValues(alpha: 0.18),
        tintBottom: AppColors.seed.withValues(alpha: 0.05),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: context.accent),
                if (trend != null)
                  AppBadge.label(
                    '${trend!.up ? '▲' : '▼'} ${trend!.percent}%',
                    tone: trend!.up ? AppTone.success : AppTone.danger,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            TweenAnimationBuilder<int>(
              key: ValueKey(value),
              tween: IntTween(begin: 0, end: value),
              duration: reduce ? Duration.zero : AppDurations.slow,
              curve: AppCurves.standard,
              builder: (context, v, _) => Text(
                unit == null ? '$v' : '$v $unit',
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Text(label, style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// A small tinted icon container — the circular/rounded badge repeated across the
/// app (drawer rows, feature tiles, blocker capsules, list avatars). Pass [icon]
/// for a default Material glyph, or [child] for anything (an animated icon,
/// initials, …). Use [gradient] for a filled brand badge.
class IconBadge extends StatelessWidget {
  const IconBadge({
    this.icon,
    this.child,
    this.size = 40,
    this.color,
    this.gradient,
    this.shape = BoxShape.circle,
    this.radius,
    this.fillAlpha = 0.14,
    this.bordered = false,
    this.borderWidth = 1,
    this.semanticLabel,
    super.key,
  }) : assert(icon != null || child != null, 'Provide an icon or a child');

  final IconData? icon;
  final Widget? child;
  final double size;

  /// Accessibility label for the default [icon]. Leave null when the badge is
  /// decorative or paired with adjacent descriptive text.
  final String? semanticLabel;

  /// Tints the fill (at [fillAlpha]), the border, and the default icon.
  /// Defaults to the live (background-adaptive) brand accent.
  final Color? color;

  /// When set, fills with this gradient instead of the tinted [color]; the
  /// default icon then renders white.
  final Gradient? gradient;
  final BoxShape shape;

  /// Corner radius when [shape] is [BoxShape.rectangle] (defaults to [AppRadius.md]).
  final double? radius;
  final double fillAlpha;
  final bool bordered;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final isCircle = shape == BoxShape.circle;
    final tint = color ?? context.accent;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: shape,
        gradient: gradient,
        color: gradient == null ? tint.withValues(alpha: fillAlpha) : null,
        borderRadius: isCircle
            ? null
            : BorderRadius.circular(radius ?? AppRadius.md),
        border: bordered
            ? Border.all(
                color: tint.withValues(alpha: 0.25),
                width: borderWidth,
              )
            : null,
      ),
      child:
          child ??
          Icon(
            icon,
            size: size * 0.5,
            color: gradient != null ? Colors.white : tint,
            semanticLabel: semanticLabel,
          ),
    );
  }
}

/// A structured content card: an optional header ([leading] + [title]/[subtitle]
/// + [trailing]), a [child] body, and a right-aligned [actions] row — all over a
/// [GlassCard]. Use [GlassCard] for a bare frosted surface, or [SectionCard] for
/// a simple titled section.
class AppCard extends StatelessWidget {
  const AppCard({
    this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.child,
    this.actions,
    this.onTap,
    this.accent,
    this.padding = AppInsets.card,
    super.key,
  });

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? child;
  final List<Widget>? actions;
  final VoidCallback? onTap;

  /// Tints the glass fill/border (e.g. [AppColors.danger] for a warning card).
  final Color? accent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hasHeader = title != null || leading != null || trailing != null;
    final hasActions = actions != null && actions!.isNotEmpty;
    return GlassCard(
      onTap: onTap,
      accent: accent,
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasHeader)
            Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null)
                        Text(
                          title!,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: text.bodySmall?.copyWith(
                            color: context.glass.onGlassMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  trailing!,
                ],
              ],
            ),
          if (child != null) ...[
            if (hasHeader) const SizedBox(height: AppSpacing.sm),
            child!,
          ],
          if (hasActions) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions!.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  actions![i],
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
