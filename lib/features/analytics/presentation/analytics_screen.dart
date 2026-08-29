import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/features/additional_feature/app_feedback/app_feedback.dart';
import 'package:detoxo/features/analytics/domain/repositories/analytics_repository.dart';
import 'package:detoxo/features/analytics/insights/domain/repositories/insights_repository.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
import 'package:detoxo/features/analytics/insights/presentation/widgets/insights_view.dart';
import 'package:detoxo/features/analytics/presentation/analytics_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/menu_button.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Two views of the user's own behaviour, behind one segmented control:
/// **Insights** (today's real screen time, from the OS's own records) and
/// **Events** (the live feed of blocks + the reel counter).
///
/// Reachable two ways that share the cubits and differ only in chrome: the
/// second HomeShell tab ([AnalyticsTab]) and the pushed drawer route
/// ([AnalyticsScreen]). The reel counter card reads the app-wide
/// `ContentCounterCubit` (provided above the router in `main.dart`).
Widget _withCubit({required Widget child}) {
  return MultiBlocProvider(
    providers: [
      BlocProvider(
        create: (_) =>
            AnalyticsCubit(sl<AnalyticsRepository>(), sl<EngineRepository>())
              ..load(),
      ),
      BlocProvider(
        create: (_) =>
            InsightsCubit(sl<InsightsRepository>(), sl<EngineRepository>())
              ..load(),
      ),
    ],
    child: child,
  );
}

/// Full-screen route (drawer → Activity): own glass app bar + back button.
class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _withCubit(
      child: const GlassScaffold(
        appBar: GlassAppBar(title: Text('Activity')),
        body: SafeArea(child: _ActivityBody()),
      ),
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
    return _withCubit(
      child: _ActivityBody(
        scrollController: scrollController,
        onMenu: onMenu,
        asTab: true,
      ),
    );
  }
}

class _ActivityBody extends StatefulWidget {
  const _ActivityBody({this.scrollController, this.onMenu, this.asTab = false});

  final ScrollController? scrollController;
  final VoidCallback? onMenu;
  final bool asTab;

  @override
  State<_ActivityBody> createState() => _ActivityBodyState();
}

class _ActivityBodyState extends State<_ActivityBody> {
  /// Insights leads: the honest numbers are the reason to open this tab, and
  /// the block feed is the supporting detail.
  int _segment = 0;

  bool get _showInsights => _segment == 0;

  /// Pull-to-refresh only has something to do on the Insights segment; the
  /// block feed is fed by the engine's stream.
  Future<void> _refresh() => _showInsights
      ? context.read<InsightsCubit>().refresh()
      : context.read<AnalyticsCubit>().load();

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d, HH:mm');
    return RefreshIndicator(
      onRefresh: _refresh,
      child: BlocBuilder<AnalyticsCubit, List<BlockEvent>>(
        builder: (context, events) {
          return ListView(
            controller: widget.scrollController,
            // Always scrollable so pull-to-refresh works on a short page (a
            // denied-permission card is only a few hundred pixels tall).
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              (widget.asTab ? AppSpacing.floatingNavClearance : AppSpacing.md) +
                  MediaQuery.viewPaddingOf(context).bottom,
            ),
            children: [
              if (widget.asTab) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Activity',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Row(
                      children: [
                        const FeedbackActionButton(),
                        DrawerMenuButton(onTap: widget.onMenu),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              GlassSegmented(
                segments: const [
                  (label: 'Insights', icon: null),
                  (label: 'Events', icon: null),
                ],
                selectedIndex: _segment,
                onChanged: (i) => setState(() => _segment = i),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_showInsights)
                const InsightsView()
              else ...[
                const ReelCounterCard(),
                const SizedBox(height: AppSpacing.lg),
                // EVO-052: what the override ledger has to say. Hides itself
                // when nothing was spent this period.
                const OverrideHistoryCard(),
                if (events.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.xl),
                    child: _Empty(),
                  )
                else
                  for (final e in events)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _EventTile(
                        event: e,
                        formatted: fmt.format(e.timestamp),
                      ),
                    ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.bar_chart,
      animatedIcon: AppIcon.activity,
      loopAnimation: true,
      title: 'Nothing blocked yet',
      subtitle: 'Block events will show up here as they happen.',
    );
  }
}

/// A single block event as a glass row: a red "blocked" badge, the surface +
/// package/mode, and a timestamp. Static icon frame — rows recycle on scroll.
class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.formatted});

  final BlockEvent event;
  final String formatted;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return GlassListTile(
      leading: IconBadge(
        size: 34,
        shape: BoxShape.rectangle,
        color: error,
        child: AppAnimatedIcon(icon: AppIcon.ban, size: 20, color: error),
      ),
      title: event.platformId,
      subtitle: '${event.packageName} · ${event.mode.wire}',
      trailing: Text(formatted, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
