import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/additional_feature/app_feedback/app_feedback.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
import 'package:detoxo/features/analytics/insights/presentation/widgets/insights_view.dart';
import 'package:detoxo/features/analytics/presentation/widgets/by_app_section.dart';
import 'package:detoxo/features/analytics/presentation/widgets/today_overview.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// One scroll of the user's own behaviour in three headed sections — an
/// uppercase `SectionHeader` over one glass panel each, the grouped-list idiom
/// the Settings and Rules screens use — then the ledger:
///
/// 1. **Today** ([TodayOverview]) — the numbers, as flat tiles in one panel:
///    Detoxo's own counts (reels, blocks) which never need a permission,
///    then the OS's (screen time, pickups) once Usage Access is granted.
/// 2. **Distraction** ([InsightsView]) — how much of the day went to apps the
///    catalog calls distracting, or the permission card that stands in for it.
/// 3. **By app** ([ByAppSection]) — the three per-app tallies behind one
///    segmented control, every row a tap from a limit.
/// 4. **Overrides** ([OverrideHistoryCard]) — the ledger, when there is one.
///
/// Each section owns its header, so the headers carry the vertical rhythm and
/// the screen places nothing between them. Reachable two ways that differ
/// only in chrome — the second HomeShell tab ([AnalyticsTab]) and the pushed
/// drawer route ([AnalyticsScreen]) — and they genuinely share their cubits:
/// `InsightsCubit` is provided app-wide and lazily in `main.dart` (EVO-058),
/// like the `ContentCounterCubit` and the `ServiceCubit` the tiles read.
/// Nothing is computed at boot; the first Activity open constructs it, and
/// every later open paints the last numbers at once and refreshes them in
/// place.

/// Full-screen route (drawer → Activity): own glass app bar + back button.
class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassScaffold(
      appBar: GlassAppBar(title: Text('Activity')),
      body: SafeArea(child: _ActivityBody()),
    );
  }
}

/// HomeShell tab body: an in-tab header + drawer button, with the list wired to
/// the floating nav bar's [scrollController] for hide-on-scroll.
class AnalyticsTab extends StatelessWidget {
  const AnalyticsTab({this.scrollController, this.onMenu, super.key});

  final ScrollController? scrollController;

  /// Opens the right-side app drawer (shared with the other tabs' headers).
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    return _ActivityBody(
      scrollController: scrollController,
      onMenu: onMenu,
      asTab: true,
    );
  }
}

class _ActivityBody extends StatelessWidget {
  const _ActivityBody({this.scrollController, this.onMenu, this.asTab = false});

  final ScrollController? scrollController;
  final VoidCallback? onMenu;
  final bool asTab;

  /// Insights recomputes (labels included), and the block and reel tiles
  /// re-read their native counters: native rolls `today` over at read time,
  /// so a pull across midnight has to ask — there may be no `blocked` or
  /// `contentCounted` event to carry the new day in. The channel legs are
  /// guarded the way the resume path guards them (`guardedSync`): a hiccup
  /// must not surface as an uncaught error from a pull gesture.
  Future<void> _refresh(BuildContext context) => Future.wait<void>([
    context.read<InsightsCubit>().refresh(),
    context.read<ServiceCubit>().refresh().catchError(
      (Object e, StackTrace s) =>
          AppLogger.e('activity: status refresh failed', e, s),
    ),
    context.read<ContentCounterCubit>().refresh().catchError(
      (Object e, StackTrace s) =>
          AppLogger.e('activity: counter refresh failed', e, s),
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: ListView(
        controller: scrollController,
        // Always scrollable so pull-to-refresh works on a short page (a
        // denied-permission card is only a few hundred pixels tall).
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          // The pushed route's app bar supplies the top gap, and the first
          // section header adds its own; the tab has a header row to inset.
          asTab ? AppSpacing.md : 0,
          AppSpacing.md,
          (asTab ? AppSpacing.floatingNavClearance : AppSpacing.md) +
              MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          if (asTab)
            Row(
              children: [
                Expanded(
                  // A heading, so swipe-by-heading lands on the screen's name
                  // before TODAY — the pushed route gets this from `AppBar`.
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Activity',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                // The Dashboard header's pair, gap included.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const FeedbackActionButton(),
                    const SizedBox(width: AppSpacing.xs),
                    DrawerMenuButton(onTap: onMenu),
                  ],
                ),
              ],
            ),
          // No gaps between the sections: each header carries `md` above and
          // `sm` below, the rhythm every grouped list in the app keeps.
          const TodayOverview(),
          const InsightsView(),
          const ByAppSection(),
          const SizedBox(height: AppSpacing.md),

          // EVO-052: what the override ledger has to say. Hides itself when
          // nothing was spent this period, and carries its own bottom gap.
          const OverrideHistoryCard(),
        ],
      ),
    );
  }
}
