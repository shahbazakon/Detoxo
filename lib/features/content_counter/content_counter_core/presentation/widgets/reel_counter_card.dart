import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/app_content_count.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/content_count.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/content_counter_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Hero card for the Activity screen: an animated count-up of short videos seen,
/// a today / all-time toggle, and an animated per-app breakdown. Reads the live
/// [ContentCounterCubit]; reduce-motion safe.
class ReelCounterCard extends StatefulWidget {
  const ReelCounterCard({super.key});

  @override
  State<ReelCounterCard> createState() => _ReelCounterCardState();
}

class _ReelCounterCardState extends State<ReelCounterCard> {
  bool _showAllTime = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContentCounterCubit, ContentCount>(
      builder: (context, count) {
        final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        final value = _showAllTime ? count.total : count.today;
        final apps = _showAllTime ? count.perAppTotal : count.perAppToday;

        return GlassCard(
          accent: Theme.of(context).colorScheme.secondary,
          padding: AppInsets.cardLg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context),
              const SizedBox(height: AppSpacing.lg),
              _heroCount(context, value: value, reduce: reduce),
              const SizedBox(height: AppSpacing.lg),
              _breakdown(
                context,
                apps: apps,
                reduce: reduce,
                counting: count.enabled,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        const IconBadge(
          size: 44,
          shape: BoxShape.rectangle,
          radius: AppRadius.md,
          gradient: AppGradients.brand,
          child: Icon(
            Icons.movie_filter_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reels seen',
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                'Short videos you scrolled',
                style: text.bodySmall?.copyWith(
                  color: context.glass.onGlassMuted,
                ),
              ),
            ],
          ),
        ),
        GlassSegmented(
          segments: const [
            (label: 'Today', icon: null),
            (label: 'All', icon: null),
          ],
          selectedIndex: _showAllTime ? 1 : 0,
          onChanged: (i) => setState(() => _showAllTime = i == 1),
          height: AppSizes.controlHeight,
          expand: false,
        ),
      ],
    );
  }

  Widget _heroCount(
    BuildContext context, {
    required int value,
    required bool reduce,
  }) {
    final text = Theme.of(context).textTheme;
    // One live-region announcement of the settled value + period, excluding the
    // per-frame tween churn so TalkBack doesn't read every intermediate number.
    return Semantics(
      liveRegion: true,
      excludeSemantics: true,
      label: '$value reels ${_showAllTime ? 'all time' : 'today'}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          TweenAnimationBuilder<int>(
            // Re-key on toggle so the figure counts up from 0 when switching
            // period; within a period, value changes animate incrementally.
            key: ValueKey(_showAllTime),
            tween: IntTween(begin: 0, end: value),
            duration: reduce ? Duration.zero : AppDurations.slow,
            curve: AppCurves.standard,
            builder: (context, v, _) => Text(
              '$v',
              style: text.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                height: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _showAllTime ? 'all time' : 'today',
              style: text.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _breakdown(
    BuildContext context, {
    required List<AppContentCount> apps,
    required bool reduce,
    required bool counting,
  }) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.glass.onGlassMuted);
    // Truthful state: with counting off, no reel can appear here — say so
    // instead of promising that opening Reels will populate the list.
    if (!counting) {
      return Text(
        'Counting is off — switch on “Count short videos” under Appearance '
        'to keep this up to date.',
        style: muted,
      );
    }
    if (apps.isEmpty) {
      return Text(
        'No reels counted yet — open Reels or Shorts and they’ll appear here.',
        style: muted,
      );
    }
    final max = apps.first.count.clamp(1, 1 << 30);
    return EntranceList(
      children: [
        for (final app in apps)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _AppRow(app: app, fraction: app.count / max, reduce: reduce),
          ),
      ],
    );
  }
}

/// A single app's tally: avatar, name + count, and an animated fill bar.
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.fraction,
    required this.reduce,
  });

  final AppContentCount app;
  final double fraction;
  final bool reduce;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        AppIconAvatar(
          iconUrl: app.iconUrl,
          appName: app.appName,
          borderRadius: AppRadius.brSm,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      app.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${app.count}',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _Bar(fraction: fraction, reduce: reduce),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.reduce});

  final double fraction;
  final bool reduce;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: AppRadius.brPill,
      child: Container(
        height: 6,
        color: context.glass.fillBottom,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
            duration: reduce ? Duration.zero : AppDurations.slow,
            curve: AppCurves.decelerate,
            builder: (context, v, _) => FractionallySizedBox(
              widthFactor: v == 0 ? 0.001 : v,
              child: Container(
                decoration: const BoxDecoration(gradient: AppGradients.brand),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
