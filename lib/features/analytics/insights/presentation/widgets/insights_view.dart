import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/core/utils/duration_format.dart';
import 'package:detoxo/features/analytics/insights/domain/entities/daily_stats.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_cubit.dart';
import 'package:detoxo/features/analytics/insights/presentation/insights_state.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

/// How many of the stored ten apps the screen draws.
const int _visibleApps = 5;

/// Today's real screen time, from the OS's own records.
///
/// Recomputes on resume when the day has rolled over — a session held open past
/// midnight must not keep showing yesterday. There is no ticker: the numbers
/// move when the user asks for them to.
class InsightsView extends StatefulWidget {
  const InsightsView({super.key});

  @override
  State<InsightsView> createState() => _InsightsViewState();
}

class _InsightsViewState extends State<InsightsView>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    return BlocBuilder<InsightsCubit, InsightsState>(
      builder: (context, state) => switch (state.status) {
        InsightsStatus.loading => const _Loading(),
        InsightsStatus.denied => const _UsageAccessCard(unknown: false),
        InsightsStatus.unavailable => const _UsageAccessCard(unknown: true),
        InsightsStatus.granted => _Metrics(state: state),
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: AppSpacing.xl),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PermissionCard(
          icon: Icons.insights_outlined,
          title: 'Usage access',
          why: unknown
              ? "Detoxo couldn't read your screen time just now."
              : 'Lets Detoxo show your real screen time, straight from '
                    "Android's own records.",
          granted: false,
          unknown: unknown,
          actionLabel: unknown ? 'Retry' : 'Grant',
          onGrant: () => unknown
              ? context.read<InsightsCubit>().refresh()
              : sl<PermissionRepository>().request(AppPermission.usageAccess),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Without it these numbers would be guesses, so Detoxo shows nothing '
          'rather than something wrong.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.glass.onGlassMuted),
        ),
      ],
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.state});

  final InsightsState state;

  @override
  Widget build(BuildContext context) {
    final stats = state.stats!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ScreenTimeHero(stats: stats, yesterday: state.yesterdayScreenTime),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Pickups',
                value: stats.pickupCount,
                icon: Icons.phonelink_ring_outlined,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: StatCard(
                label: 'App switches',
                value: stats.contextSwitches,
                icon: Icons.swap_horiz_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Distracting opens',
                value: stats.distractionOpens,
                icon: Icons.open_in_new_rounded,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: StatCard(
                label: 'Reels seen',
                value: stats.reelCount,
                icon: Icons.movie_filter_rounded,
              ),
            ),
          ],
        ),
        if (stats.firstPickup != null && stats.lastPickup != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _PickupWindow(stats: stats),
        ],
        if (stats.topApps.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _TopApps(stats: stats, apps: state.apps),
        ],
        const SizedBox(height: AppSpacing.lg),
        _Footnote(stats: stats),
      ],
    );
  }
}

/// The headline: total screen time, and how much of it went to apps the catalog
/// calls distracting.
class _ScreenTimeHero extends StatelessWidget {
  const _ScreenTimeHero({required this.stats, this.yesterday});

  final DailyStats stats;

  /// Yesterday's finished total, or null when there isn't one yet.
  final Duration? yesterday;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = context.glass.onGlassMuted;
    // Clamped: `computeDailyStats` cannot exceed 100%, but a corrupt stored
    // record can, and "153% of your day" is worse than a rounded truth.
    final share = (stats.distractionShare.clamp(0.0, 1.0) * 100).round();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconBadge(
                size: 34,
                shape: BoxShape.rectangle,
                gradient: AppGradients.brand,
                child: Icon(
                  Icons.schedule_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Screen time today',
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            excludeSemantics: true,
            label: 'Screen time today, ${formatHm(stats.screenTime)}',
            child: Text(
              formatHm(stats.screenTime),
              style: text.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                height: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (yesterday != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              // A plain reference, not a verdict. Today is still running, so
              // any percentage against yesterday's *whole* day would read as a
              // triumph every morning and a defeat every night.
              'Yesterday: ${formatHm(yesterday!)}',
              style: text.bodySmall?.copyWith(color: muted),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          ProgressBar(
            progress: stats.distractionShare,
            animate: true,
            semanticLabel: stats.screenTimeMs == 0
                ? 'No screen time recorded yet today'
                : '${formatHm(stats.distraction)} distracting, '
                      '$share percent of your day',
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            stats.screenTimeMs == 0
                ? 'Nothing recorded yet today'
                : '${formatHm(stats.distraction)} distracting · $share% of '
                      'your day',
            style: text.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

/// First and last screen-on of the day — the shape of the day, not just its
/// size.
class _PickupWindow extends StatelessWidget {
  const _PickupWindow({required this.stats});

  final DailyStats stats;

  @override
  Widget build(BuildContext context) {
    final first = TimeOfDay.fromDateTime(stats.firstPickup!).format(context);
    final last = TimeOfDay.fromDateTime(stats.lastPickup!).format(context);
    return GlassListTile(
      leading: const IconBadge(icon: Icons.wb_twilight_rounded, size: 34),
      title: 'First pickup $first',
      subtitle: 'Last so far $last',
    );
  }
}

/// Where the time actually went, longest first.
class _TopApps extends StatelessWidget {
  const _TopApps({required this.stats, required this.apps});

  final DailyStats stats;
  final Map<String, InstalledApp> apps;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final shown = stats.topApps.take(_visibleApps).toList();
    // Bars are relative to the busiest app, not to the whole day — otherwise
    // every bar is a sliver on a day with a long tail.
    final busiest = shown.first.foregroundMillis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Where it went',
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final app in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _AppRow(
              usage: app,
              installed: apps[app.package],
              fraction: busiest == 0 ? 0 : app.foregroundMillis / busiest,
            ),
          ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.usage,
    required this.installed,
    required this.fraction,
  });

  final AppUsage usage;

  /// Null when the app is not in the engine's installed list (uninstalled since
  /// the usage was recorded, or the lookup failed) — the row still renders,
  /// labelled by package name.
  final InstalledApp? installed;
  final double fraction;

  /// EVO-033: the one place this screen stops being a report.
  ///
  /// Detoxo's whole argument is that a chart the next morning is too late
  /// (`docs/info_docs/01-product-overview.md`, "The problem"). Seeing "1h 10m"
  /// against an app is exactly the moment a limit gets set, so the row opens
  /// the rule editor pre-filled for that app instead of leaving the user to
  /// find Rules and rebuild the thought. Never a silent save — the editor is
  /// where they pick the hours (the EVO-031 preset rule).
  Future<void> _limitThisApp(BuildContext context, String label) {
    return context.push(
      Routes.ruleEditor,
      extra: RuleEditorArgs(
        kind: RuleKind.timeLimit,
        rule: Rule(
          id: const Uuid().v4(),
          name: 'Limit $label',
          kind: RuleKind.timeLimit,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          // thresholdMs stays at its 0 default on purpose: the editor makes
          // the user choose a budget rather than accepting one Detoxo invented.
          selection: RuleSelection(apps: [usage.package]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = installed?.appName.isNotEmpty ?? false
        ? installed!.appName
        : usage.package;
    // `ExcludeSemantics` sits *inside* the tappable, not around it: excluding
    // at the top would swallow InkWell's own tap action and leave a screen
    // reader announcing a button it cannot activate.
    return Semantics(
      button: true,
      label: '$label, ${formatHm(usage.foreground)}. Set a daily limit',
      child: InkWell(
        borderRadius: AppRadius.brMd,
        onTap: () => _limitThisApp(context, label),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
          child: ExcludeSemantics(child: _row(context, text, label)),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, TextTheme text, String label) {
    return Row(
      children: [
        AppIconAvatar(
          iconUrl: '',
          iconBytes: installed?.icon,
          appName: label,
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
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    formatHm(usage.foreground),
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xxs),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: context.glass.onGlassMuted,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxs),
              ProgressBar(progress: fraction, height: 6, animate: true),
            ],
          ),
        ),
      ],
    );
  }
}

/// States the limits of the numbers above rather than letting the user assume
/// they are more precise than they are.
class _Footnote extends StatelessWidget {
  const _Footnote({required this.stats});

  final DailyStats stats;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Screen time, distraction time and the app list come from Android’s own '
      'records — the same ones Digital Wellbeing reads, so they count an app '
      'that was open but idle. Reels seen is Detoxo’s own count and undercounts '
      'quiet playback; opens and switches are counted from app changes. '
      '${stats.complete ? '' : 'Today is still running. '}'
      'History starts the day you first opened this screen.',
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: context.glass.onGlassMuted),
    );
  }
}
