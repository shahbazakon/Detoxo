import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/utils/duration_format.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The day in four flat tiles under one **Today** header, in one glass panel:
/// Detoxo's own two counts (reels, blocks) which never need a permission, then
/// the OS's two (screen time, pickups) once Usage Access is granted. Each tile
/// carries at most one neutral reference under its number — all-time or
/// yesterday, the first pickup — never a verdict.
///
/// The tiles are `contained: false`: the panel is the surface, a hairline
/// separates the two rows, and nothing is glass-on-glass.
class TodayOverview extends StatelessWidget {
  const TodayOverview({super.key});

  @override
  Widget build(BuildContext context) {
    final (reels, reelsTotal) = context.select(
      (ContentCounterCubit c) => (c.state.today, c.state.total),
    );
    final (blocks, blocksTotal, blocksYesterday) = context.select(
      (ServiceCubit c) =>
          (c.state.blocksToday, c.state.blocksTotal, c.state.blocksYesterday),
    );
    // Selected, not watched: the cubit's second, labels-only emit must not
    // re-run four tweens for a map this section never reads.
    final (stats, yesterday) = context.select(
      (InsightsCubit c) =>
          (c.state.hasData ? c.state.stats : null, c.state.yesterdayScreenTime),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Today'),
        GlassCard(
          // The tiles keep their own `sm` padding, so their text sits 16 dp in
          // from the rim (`AppInsets.card`) and the hairline runs level with it.
          padding: const EdgeInsets.all(AppSpacing.xxs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StatCardPair(
                StatCard(
                  compact: true,
                  contained: false,
                  label: 'Reels',
                  value: reels,
                  icon: Icons.movie_filter_rounded,
                  // The same zero rule as the tile beside it: no history, no
                  // reference.
                  caption: reelsTotal > 0 ? 'All time: $reelsTotal' : null,
                ),
                StatCard(
                  compact: true,
                  contained: false,
                  label: 'Blocked',
                  value: blocks,
                  icon: Icons.block,
                  // Yesterday only once a day before this one holds blocks:
                  // the native counter has no "no record" value, so on day
                  // one `total > 0` would print the "Yesterday: 0" it means
                  // to avoid.
                  caption: blocksTotal > blocks
                      ? 'Yesterday: $blocksYesterday'
                      : blocksTotal > 0
                      ? 'All time: $blocksTotal'
                      : null,
                ),
              ),
              if (stats != null) ...[
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: AppSpacing.sm,
                  endIndent: AppSpacing.sm,
                  color: context.glass.border,
                ),
                StatCardPair(
                  StatCard(
                    compact: true,
                    contained: false,
                    label: 'Screen time',
                    text: formatHm(stats.screenTime),
                    icon: Icons.schedule_rounded,
                    // A plain reference, not a percentage: today is still
                    // running, so any ratio against a whole yesterday would
                    // read as a triumph every morning and a defeat every
                    // night.
                    caption: yesterday == null
                        ? null
                        : 'Yesterday: ${formatHm(yesterday)}',
                  ),
                  StatCard(
                    compact: true,
                    contained: false,
                    label: 'Pickups',
                    value: stats.pickupCount,
                    icon: Icons.wb_twilight_rounded,
                    caption: stats.firstPickup == null
                        ? null
                        : 'First ${TimeOfDay.fromDateTime(stats.firstPickup!).format(context)}',
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
