import 'dart:math' as math;

import 'package:detoxo/core/design_system/foundations/animated_icons.dart';
import 'package:detoxo/core/design_system/foundations/glass_container.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_blur.dart';
import 'package:detoxo/core/design_system/tokens/app_motion.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// Branded loading indicator (replaces bare `CircularProgressIndicator`).
class LoadingState extends StatelessWidget {
  const LoadingState({this.message, super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: context.accent,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// A shimmering placeholder block for skeleton screens.
class Skeleton extends StatelessWidget {
  const Skeleton({
    this.width,
    this.height = 16,
    this.radius = AppRadius.sm,
    super.key,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: context.glass.fillTop,
            borderRadius: BorderRadius.circular(radius),
          ),
        )
        .animate(onPlay: (c) => c.repeat())
        .shimmer(
          duration: 1200.ms,
          color: context.glass.onGlassMuted.withValues(alpha: 0.12),
        );
  }
}

/// A circular progress ring with centred content — used by the pause countdown.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    required this.progress,
    this.size = 220,
    this.strokeWidth = 24,
    this.color,
    this.arcColor,
    this.child,
    super.key,
  });

  /// 0..1 remaining fraction.
  final double progress;
  final double size;
  final double strokeWidth;

  /// Reserved tint override; the ring otherwise uses the live brand sweep.
  final Color? color;

  /// Optional solid arc tone. When null the arc uses the brand sweep gradient;
  /// when set (e.g. a usage-vs-limit ladder color) the whole arc + glow adopt it.
  final Color? arcColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Raised glass disc nested inside the arc. Sized to ~72% so a clear
          // gap sits between the arc and the disc (the depth cue). A true circle
          // (not the squircle) so it follows the ring; GlassContainer supplies
          // the soft elevation shadow so it reads as floating above the card.
          SizedBox(
            width: size * 0.72,
            height: size * 0.72,
            child: const GlassContainer(
              blurSigma: AppBlur.hero,
              circle: true,
              padding: EdgeInsets.zero,
              child: SizedBox.expand(),
            ),
          ),
          CustomPaint(
            size: Size.square(size),
            painter: _RingPainter(
              progress: progress.clamp(0, 1),
              strokeWidth: strokeWidth,
              trackColor: context.glass.border,
              arcColor: arcColor,
              accent: Theme.of(context).colorScheme.secondary,
              accentAlt: Theme.of(context).colorScheme.primary,
            ),
          ),
          ?child,
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.trackColor,
    required this.accent,
    required this.accentAlt,
    this.arcColor,
  });

  final double progress;
  final double strokeWidth;
  final Color trackColor;

  /// Live brand colours (background-adaptive) for the sweep + glow.
  final Color accent;
  final Color accentAlt;
  final Color? arcColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = -math.pi / 2;
    final sweep = math.pi * 2 * progress;

    // Faint full-circle track.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = trackColor,
    );

    if (progress <= 0) return;

    // Glowing bead at the leading edge of the arc.
    final angle = start + sweep;
    final tip = center + Offset(math.cos(angle), math.sin(angle)) * radius;

    // Bloom/bead tone follows the arc color when one is supplied.
    final glow = arcColor ?? accent;

    canvas
      // Ambient bloom: a wider, blurred copy of the arc glowing behind it.
      ..drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth + 6
          ..strokeCap = StrokeCap.round
          ..color = glow.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      )
      // Crisp arc: a solid laddered tone when [arcColor] is given, else the
      // brand sweep gradient (mint → bright violet → mint).
      ..drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..shader = arcColor == null
              ? SweepGradient(
                  colors: [accent, accentAlt, accent],
                ).createShader(rect)
              : null
          ..color = glow,
      )
      // Bead glow, then bright core.
      ..drawCircle(
        tip,
        strokeWidth * 0.9,
        Paint()
          ..color = glow.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      )
      ..drawCircle(tip, strokeWidth * 0.42, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.arcColor != arcColor ||
      old.accent != accent ||
      old.accentAlt != accentAlt;
}

/// A glass linear progress bar (daily-limit usage, permissions completion,
/// the insights distraction share and per-app split).
///
/// The **one** proportion bar in the app: private re-implementations kept
/// drifting apart (6 px here, 8 px there). Set [animate] for the growing fill;
/// it is opt-in so the existing static call sites are untouched.
class ProgressBar extends StatelessWidget {
  const ProgressBar({
    required this.progress,
    this.height = 8,
    this.animate = false,
    this.semanticLabel,
    super.key,
  });

  final double progress;
  final double height;

  /// Grow the fill on change instead of snapping. Honours the OS "remove
  /// animations" setting.
  final bool animate;

  /// What a screen reader announces. A bare bar contributes no semantics node
  /// at all, so a caller whose value is not already in adjacent text must pass
  /// this or the information is silently unavailable.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final target = progress.clamp(0.0, 1.0);
    final fill = Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.secondary,
            Theme.of(context).colorScheme.primary,
          ],
        ),
        borderRadius: BorderRadius.circular(height),
      ),
    );
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Stack(
        children: [
          Container(height: height, color: context.glass.border),
          if (animate && !reduce)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: target),
              duration: AppDurations.slow,
              curve: AppCurves.decelerate,
              // `child` is built once and handed back each frame — the fill is
              // not reallocated 30 times per animation.
              child: fill,
              builder: (context, v, child) => FractionallySizedBox(
                // A zero-width FractionallySizedBox lays out as unconstrained;
                // a hairline keeps it a no-op.
                widthFactor: v == 0 ? 0.001 : v,
                child: child,
              ),
            )
          else
            FractionallySizedBox(
              widthFactor: target == 0 ? 0.001 : target,
              child: fill,
            ),
        ],
      ),
    );
    return semanticLabel == null
        ? bar
        : Semantics(label: semanticLabel, container: true, child: bar);
  }
}

/// A friendly empty / placeholder state. Pass [animatedIcon] for a morphing
/// glyph — [loopAnimation] runs it continuously (ambient), otherwise it plays
/// once on appear.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.animatedIcon,
    this.loopAnimation = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final AppIcon? animatedIcon;
  final bool loopAnimation;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (animatedIcon != null)
              AppAnimatedIcon(
                icon: animatedIcon!,
                size: 44,
                color: outline,
                loop: loopAnimation,
                playOnAppear: !loopAnimation,
              )
            else
              Icon(icon, size: 44, color: outline),
            const SizedBox(height: AppSpacing.sm),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
