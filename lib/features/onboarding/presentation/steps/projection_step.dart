import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:flutter/material.dart';

/// The cost of the answer the user just gave, in the only unit that lands:
/// whole days, counted up rather than stated. Pure arithmetic on the band's
/// midpoint — nothing here is a projection of *their* data, so the copy says
/// "at this rate" and never claims to have measured anything.
class ProjectionStep extends StatelessWidget {
  const ProjectionStep({
    required this.progress,
    required this.accent,
    super.key,
  });

  final OnboardingProgress progress;
  final Color accent;

  /// The horizon the headline is expressed over. Five years is long enough to
  /// be startling and short enough to still feel like your own life.
  static const int _years = 5;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final band = progress.band;
    final perYear = progress.daysPerYear;
    // The band is answered before this step is reachable, but a resumed record
    // written by an older build could arrive without one — render the step
    // without the number rather than throwing on a null.
    final total = perYear == null ? null : perYear * _years;

    // A ListView, like every sibling step. As a bare Column inside fixed 96/168
    // padding this overflowed at large text scales — the count-up is
    // displayMedium, so it is the step with the least headroom to spare.
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 96, AppSpacing.xl, 168),
      shrinkWrap: true,
      children: [
        if (total != null) ...[
          _DayCountUp(days: total, accent: accent),
          const SizedBox(height: AppSpacing.md),
          Text(
            'days of your next $_years years',
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(color: context.glass.onGlass),
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
        Text(
          'That’s the maths, not a judgement',
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          band == null
              ? 'Short-form feeds are built to never end. The time goes '
                    'somewhere, and it is rarely where you meant it to.'
              : 'At ${band.label.toLowerCase()} a day, that is about '
                    '$perYear full days a year — awake, scrolling. You did '
                    'not choose that; the feed did.',
          textAlign: TextAlign.center,
          style: text.bodyLarge?.copyWith(color: context.glass.onGlass),
        ),
      ],
    );
  }
}

/// Counts to [days] once. Under reduce-motion it renders the end state — the
/// number is the point, the animation is not.
class _DayCountUp extends StatelessWidget {
  const _DayCountUp({required this.days, required this.accent});

  final int days;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: reduceMotion ? days : 0, end: days),
      duration: AppDurations.slow,
      curve: AppCurves.decelerate,
      builder: (context, v, _) => ShaderMask(
        shaderCallback: (b) => context.metricGradient.createShader(b),
        blendMode: BlendMode.srcIn,
        child: Text(
          '$v',
          semanticsLabel: '$days days',
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
