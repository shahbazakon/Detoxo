import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/utils/duration_format.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
import 'package:detoxo/features/analytics/presentation/widgets/app_limit_row.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Which per-app tally the section shows.
enum ByAppSegment {
  reels('Reels'),
  blocks('Blocks'),
  time('Time');

  const ByAppSegment(this.label);

  final String label;
}

/// One row's worth of figures, whatever the segment counts — sorted, capped
/// and normalised by [ByAppSection.rowsFor] so the widget only draws.
typedef ByAppRow = ({
  String package,
  String? name,
  String iconUrl,
  String trailing,
  String? spoken,
  double fraction,
});

/// The three per-app tallies — reels seen, blocks, screen time — under one
/// **By app** header: a segmented control over one glass panel of
/// [AppLimitRow]s (EVO-033: the number is the way to a limit). Replaced three
/// lists in three styles on the old screen.
///
/// Every segment is today: the block tally is native (`ConfigStore`, bounded,
/// rolled at read time — a Dart-side one only saw blocks while the UI was
/// alive), the reel list is the live counter's, and the time list is the OS's
/// own. Labels and icons are `InsightsState.apps`, the screen's one
/// installed-app lookup; a failure costs the labels, never the rows.
class ByAppSection extends StatefulWidget {
  const ByAppSection({super.key});

  /// How many of the stored ten screen-time apps the Time segment draws.
  static const int visibleTimeApps = 5;

  /// The rows for [segment], busiest first, bars relative to the busiest —
  /// never to the day's total, or every bar is a sliver on a day with a long
  /// tail. Pure: the sort, the cap and the zero guard live here so a test can
  /// reach them (the `StreakCubit.advance` idiom).
  @visibleForTesting
  static List<ByAppRow> rowsFor(
    ByAppSegment segment, {
    required ContentCount count,
    required Map<String, int> blocks,
    DailyStats? stats,
  }) {
    final raw = switch (segment) {
      // The counter documents its lists as sorted by count, descending.
      ByAppSegment.reels => [
        for (final a in count.perAppToday)
          (
            package: a.packageName,
            name: a.displayName,
            iconUrl: a.iconUrl,
            weight: a.count,
            trailing: '${a.count}',
            spoken: a.count == 1 ? '1 reel' : '${a.count} reels',
          ),
      ],
      ByAppSegment.blocks => [
        for (final e
            in blocks.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
          (
            package: e.key,
            name: null,
            iconUrl: '',
            weight: e.value,
            trailing: '${e.value}',
            spoken: e.value == 1 ? '1 block' : '${e.value} blocks',
          ),
      ],
      // `DailyStats` re-sorts `topApps` on read.
      ByAppSegment.time => [
        for (final a in (stats?.topApps ?? const <AppUsage>[]).take(
          visibleTimeApps,
        ))
          (
            package: a.package,
            name: null,
            iconUrl: '',
            weight: a.foregroundMillis,
            trailing: formatHm(a.foreground),
            spoken: null,
          ),
      ],
    };
    final busiest = raw.isEmpty ? 0 : raw.first.weight;
    return <ByAppRow>[
      for (final r in raw)
        (
          package: r.package,
          name: r.name,
          iconUrl: r.iconUrl,
          trailing: r.trailing,
          spoken: r.spoken,
          fraction: busiest == 0 ? 0.0 : r.weight / busiest,
        ),
    ];
  }

  /// What an empty [segment] says, and why — truthful about counting being
  /// off rather than promising that opening Reels will fill the list.
  @visibleForTesting
  static String emptyCopy(ByAppSegment segment, {required bool counting}) =>
      switch (segment) {
        ByAppSegment.reels when !counting =>
          'Counting is off. Turn it on under Appearance.',
        ByAppSegment.reels => 'No reels counted yet.',
        ByAppSegment.blocks => 'No blocks yet today.',
        ByAppSegment.time => 'Nothing yet today.',
      };

  @override
  State<ByAppSection> createState() => _ByAppSectionState();
}

class _ByAppSectionState extends State<ByAppSection>
    with AutomaticKeepAliveClientMixin {
  int _index = 0;

  /// The Activity list is lazy: a section scrolled past the cache extent is
  /// disposed, which would reset the chosen segment to Reels on the way back.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final count = context.watch<ContentCounterCubit>().state;
    final blocks = context.select((ServiceCubit c) => c.state.blocksByPackage);
    final insights = context.watch<InsightsCubit>().state;
    final stats = insights.hasData ? insights.stats : null;

    final segments = [
      ByAppSegment.reels,
      ByAppSegment.blocks,
      if (stats != null) ByAppSegment.time,
    ];
    // A revoked grant drops the Time segment from under a selection. The
    // stored index is kept, so Time re-selects when the grant returns; the
    // pill and the rows always agree because both derive from [segment].
    final segment = segments[_index.clamp(0, segments.length - 1)];
    final rows = ByAppSection.rowsFor(
      segment,
      count: count,
      blocks: blocks,
      stats: stats,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('By app'),
        GlassSegmented(
          segments: [for (final s in segments) (label: s.label, icon: null)],
          selectedIndex: segments.indexOf(segment),
          onChanged: (i) => setState(() => _index = i),
          height: AppSizes.controlHeight,
        ),
        // `lg`, not `sm`: the control is the one glass surface that casts a
        // shadow, and the card around it used to clip that. Bare, the shadow
        // reaches ~20 dp down, and the panel's backdrop blur would smear it
        // across its top rim at a narrower gap.
        const SizedBox(height: AppSpacing.lg),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rows.isEmpty)
                Text(
                  ByAppSection.emptyCopy(segment, counting: count.enabled),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.glass.onGlassMuted,
                  ),
                )
              else
                for (var i = 0; i < rows.length; i++) ...[
                  // The rows carry `xs` of their own vertical padding (the
                  // 48 dp floor), so the gap between them stays small.
                  if (i > 0) const SizedBox(height: AppSpacing.xxs),
                  AppLimitRow(
                    key: ValueKey(rows[i].package),
                    package: rows[i].package,
                    installed: insights.apps[rows[i].package],
                    name: rows[i].name,
                    iconUrl: rows[i].iconUrl,
                    trailing: rows[i].trailing,
                    spokenTrailing: rows[i].spoken,
                    fraction: rows[i].fraction,
                  ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}
