import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/utils/duration_format.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_state.dart';
import 'package:detoxo/features/permissions/permissions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The **Distraction** section — how much of today's screen time went to apps
/// the catalog calls distracting — or the permission card that stands in for
/// it, under the one header either way. The headline figures (screen time,
/// pickups) and the per-app list live in the Activity screen's own
/// `TodayOverview` and `ByAppSection`, which read the same cubit; this view
/// owns the cubit's lifecycle.
///
/// Refreshes on every mount and on resume — a session held open past midnight
/// must not keep showing yesterday, and a grant revoked in Settings must not
/// keep showing numbers. There is no ticker: the numbers move when the user
/// asks for them to.
class InsightsView extends StatefulWidget {
  const InsightsView({super.key});

  @override
  State<InsightsView> createState() => _InsightsViewState();
}

class _InsightsViewState extends State<InsightsView>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  /// The Activity list is lazy: scrolled past the cache extent this state is
  /// disposed, and the next scroll back would re-run the mount refresh — two
  /// channel queries, the fold and a Hive write — for nothing.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // EVO-058: the cubit outlives this view (provided app-wide and lazily), so
    // a later mount already holds numbers — `refresh()` keeps them on screen
    // and recomputes in place. Only the process's very first mount shows the
    // spinner. Safe unawaited: `_compute` never throws.
    unawaited(context.read<InsightsCubit>().refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Cheap: a no-op unless the cached day key is stale. Fire-and-forget like
    // every other resume leg (`app_resume_sync.dart`) — safe unawaited because
    // `_compute` never throws, it emits `unavailable` instead.
    unawaited(context.read<InsightsCubit>().refreshIfStale());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return BlocBuilder<InsightsCubit, InsightsState>(
      // The header in every state, so the section keeps its place and its
      // heading whether it holds numbers, a spinner or the Grant card.
      builder: (context, state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            // `start`: the 48 dp button is taller than the header block, and
            // top-aligned its icon sits level with the label.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: SectionHeader('Distraction')),
              IconButton(
                tooltip: 'About these numbers',
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => _showAboutSheet(context),
              ),
            ],
          ),
          switch (state.status) {
            InsightsStatus.loading => const _Loading(),
            InsightsStatus.denied => const _UsageAccessCard(unknown: false),
            InsightsStatus.unavailable => const _UsageAccessCard(unknown: true),
            InsightsStatus.granted => _DistractionCard(stats: state.stats!),
          },
        ],
      ),
    );
  }
}

/// The spinner inside a panel, so the section reserves its space instead of
/// jumping when the numbers arrive.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const GlassCard(
      child: LoadingState(message: 'Reading your screen time…'),
    );
  }
}

/// Usage Access is missing or the engine did not answer.
///
/// This is the whole reason the screen has a state machine: rendering `0 m`
/// here would be indistinguishable from a genuinely quiet day, which is a
/// confident lie (EVO-014). [unknown] separates "we could not read the status"
/// from "you have not granted it".
class _UsageAccessCard extends StatelessWidget {
  const _UsageAccessCard({required this.unknown});

  final bool unknown;

  @override
  Widget build(BuildContext context) {
    return PermissionCard(
      icon: Icons.insights_outlined,
      title: 'Usage access',
      why: unknown
          ? "Couldn't read your screen time."
          : 'Needed to show your screen time.',
      granted: false,
      unknown: unknown,
      actionLabel: unknown ? 'Retry' : 'Grant',
      // Through the one entry point, never the repository directly: it is
      // what routes an Android 13+ restricted-settings dead end to the
      // walkthrough instead of another trip to a toggle that won't flip.
      onGrant: () => unknown
          ? context.read<InsightsCubit>().refresh()
          : requestPermission(context, AppPermission.usageAccess),
    );
  }
}

/// How much of the day went to distracting apps, in one glass panel: a share
/// bar with its caption, a hairline, then the two counts that explain it
/// (switches, opens) as flat tiles.
class _DistractionCard extends StatelessWidget {
  const _DistractionCard({required this.stats});

  final DailyStats stats;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Clamped: `computeDailyStats` cannot exceed 100%, but a corrupt stored
    // record can, and "153% of screen time" is worse than a rounded truth.
    final share = (stats.distractionShare.clamp(0.0, 1.0) * 100).round();
    final quiet = stats.screenTimeMs == 0;
    final line = quiet
        ? 'Nothing yet today'
        : '${formatHm(stats.distraction)} · $share% of screen time';
    return GlassCard(
      // The flat tiles keep their own `sm` padding; the bar block takes the
      // same, so text and hairline sit level at 16 dp from the rim.
      padding: const EdgeInsets.all(AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            // One spoken sentence for the bar and its caption, derived from
            // the visible line: the "·" is silence to TalkBack and "%" a
            // guess, so a comma and the word (the `StatCard` rule).
            child: Semantics(
              label: line.replaceAll(' · ', ', ').replaceAll('%', ' percent'),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProgressBar(progress: stats.distractionShare, animate: true),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    line,
                    style: text.bodySmall?.copyWith(
                      color: context.glass.onGlassMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
              label: 'App switches',
              value: stats.contextSwitches,
              icon: Icons.swap_horiz_rounded,
            ),
            StatCard(
              compact: true,
              contained: false,
              label: 'Distracting opens',
              value: stats.distractionOpens,
              icon: Icons.open_in_new_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the info button beside the DISTRACTION header opens: where each number
/// on the screen comes from, so nobody assumes more precision than there is.
/// Replaced a paragraph that sat under every section.
Future<void> _showAboutSheet(BuildContext context) {
  return GlassBottomSheet.show<void>(
    context: context,
    title: 'About these numbers',
    child: SingleChildScrollView(
      child: Text(
        'Screen time, distraction time and the app list come from Android’s '
        'records — the same ones Digital Wellbeing reads — so an app left open '
        'but idle still counts.\n\n'
        'Opens and switches are counted from app changes.\n\n'
        'Reels and blocks are Detoxo’s own counts; quiet playback can be '
        'undercounted.\n\n'
        'Screen-time history starts the day you first opened this screen.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: context.glass.onGlassMuted),
      ),
    ),
  );
}
