import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/animated_digit_timer.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/countdown_ring.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/stat_pill.dart';
import 'package:flutter/material.dart';

/// A live Pause / Conscious session rendered in the hero ring: a 0..1 [progress]
/// fill, the [remaining] time as ticking digits, a short [caption], and an
/// optional animated [icon]. When present it replaces the idle TIME-SAVED ring.
class SessionCountdown {
  const SessionCountdown({
    required this.progress,
    required this.remaining,
    required this.caption,
    this.tone = AppTone.accent,
    this.icon,
  });

  /// 0..1 ring fill (remaining fraction for Pause, banked fraction for Conscious).
  final double progress;
  final Duration remaining;

  /// A one- or two-word live state shown in the ring, e.g. "reels allowed".
  final String caption;
  final AppTone tone;

  /// Optional animated icon shown above the digits (e.g. [AppIcon.pause]).
  final AppIcon? icon;
}

/// The unified hero ("Command Center"): a gradient progress ring around the
/// primary metric, a live status badge, two secondary stat pills, and the
/// integrated mode toggle — all inside one glass panel with ambient corner
/// glows.
class CommandCenterCard extends StatelessWidget {
  const CommandCenterCard({
    required this.timeToday,
    required this.progress,
    required this.limitLabel,
    required this.statusLabel,
    required this.streakValue,
    required this.reelsValue,
    this.overLimit = false,
    this.countdown,
    super.key,
  });

  /// Formatted screen time spent in monitored social apps today (e.g. "1h 12m").
  final String timeToday;

  /// 0..1 ring fill — today's usage over the user's daily limit.
  final double progress;

  /// Sub-line under the time, e.g. "of 2h 0m" or "20m over your limit".
  final String limitLabel;

  /// True once today's usage reaches/exceeds the limit (red ring + sub-line).
  final bool overLimit;

  final String statusLabel;

  /// Consecutive days the user stayed under their daily limit.
  final String streakValue;

  /// Reels counted today (real on-device count).
  final String reelsValue;

  /// When a Pause / Conscious / One Reel session is live, the hero ring becomes
  /// this countdown gauge instead of the TIME-SAVED ring.
  final SessionCountdown? countdown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Stack(
      children: [
        SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: 240,
                height: 240,
                child: countdown == null
                    ? _screenTimeRing(context, text, scheme)
                    : _countdownRing(context, text, countdown!),
              ),
              const SizedBox(height: AppSpacing.md),
              StatStrip(
                stats: [
                  StatPill(
                    icon: Icons.play_circle_outline,
                    value: reelsValue,
                    label: 'reels today',
                    iconColor: scheme.secondary,
                  ),
                  StatPill(
                    icon: Icons.local_fire_department,
                    value: streakValue,
                    label: 'day streak',
                    iconColor: AppColors.warning,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The idle hero: a gradient ring around today's SCREEN-TIME metric, filling
  /// toward the user's daily limit. The arc animates on change and shifts
  /// green → amber → red as usage approaches (then crosses) the limit.
  Widget _screenTimeRing(
    BuildContext context,
    TextTheme text,
    ColorScheme scheme,
  ) {
    final ringColor = AppColors.limitTone(progress, over: overLimit);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: progress),
      duration: AppDurations.slow,
      curve: AppCurves.standard,
      builder: (context, value, _) => ProgressRing(
        progress: value,
        size: 240,
        arcColor: ringColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'SCREEN TIME',
              style: text.labelSmall?.copyWith(
                color: scheme.secondary,
                letterSpacing: 2,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              width: 170,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ShaderMask(
                  shaderCallback: (bounds) =>
                      (overLimit
                              ? AppGradients.overLimit
                              : context.metricGradient)
                          .createShader(bounds),
                  blendMode: BlendMode.srcIn,
                  child: Text(
                    timeToday,
                    style: text.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              limitLabel,
              style: text.labelSmall?.copyWith(
                color: overLimit ? AppColors.danger : scheme.onSurfaceVariant,
                fontWeight: overLimit ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            _StatusBadge(label: statusLabel),
          ],
        ),
      ),
    );
  }

  /// The live hero: the read-only countdown gauge with ticking digits, an
  /// animated emoji and a state pill.
  Widget _countdownRing(
    BuildContext context,
    TextTheme text,
    SessionCountdown cd,
  ) {
    final icon = cd.icon;
    return CountdownRing(
      progress: cd.progress,
      center: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppAnimatedIcon(
              icon: icon,
              size: 30,
              color: Theme.of(context).colorScheme.secondary,
              playOnAppear: true,
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          AnimatedDigitTimer(
            remaining: cd.remaining,
            style: text.headlineSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          Pill(label: cd.caption, tone: cd.tone),
        ],
      ),
    );
  }
}

/// Pulsing dot + uppercase plan label, e.g. "● CONSCIOUS".
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs + 2,
      ),
      decoration: BoxDecoration(
        color: scheme.secondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: scheme.secondary, size: 6),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.secondary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
