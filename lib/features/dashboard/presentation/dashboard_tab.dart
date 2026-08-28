import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/additional_feature/showcase_view/showcase_view.dart';
import 'package:detoxo/features/blocking/engine/presentation/service_cubit.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/session_defaults.dart';
import 'package:detoxo/features/blocking/plans/presentation/conscious_cubit.dart';
import 'package:detoxo/features/blocking/plans/presentation/reel_session_cubit.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/session_dialogs.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/content_counter_cubit.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/blocker_section.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/command_center_card.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/dashboard_top_bar.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/mode_selector.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/protection_status_card.dart';
import 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_cubit.dart';
import 'package:detoxo/features/limits/streak/presentation/streak_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class DashboardTab extends StatefulWidget {
  const DashboardTab({this.scrollController, this.onMenu, super.key});

  final ScrollController? scrollController;

  /// Opens the right-side app drawer (former "More" tab).
  final VoidCallback? onMenu;

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  /// The one-time feature tour runs as soon as the dashboard is front-most and
  /// `hasSeenFeatureShowcase` is false. We keep it "pending" and poll for the
  /// dashboard becoming current, so a replay requested from Settings reliably
  /// starts once we navigate back here — without depending on this widget
  /// rebuilding (go_router may reuse the existing element).
  bool _tourPending = false;
  bool _tourRunning = false;
  int _startAttempts = 0;

  /// Frame budget to wait for the dashboard to become front-most (~2s at 60fps)
  /// before giving up; a fresh dashboard mount retries from scratch.
  static const _maxStartAttempts = 120;

  @override
  void initState() {
    super.initState();
    _queueTour();
  }

  /// (Re)arms the tour and kicks off the first start attempt.
  void _queueTour() {
    _tourPending = true;
    _tourRunning = false;
    _startAttempts = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryStartTour());
  }

  void _tryStartTour() {
    if (!mounted || !_tourPending || _tourRunning) return;
    if (context.read<SettingsCubit>().state.hasSeenFeatureShowcase) {
      _tourPending = false;
      return;
    }
    // Defer until the dashboard is the front-most route (e.g. after returning
    // from Settings for a replay), retrying each frame within the budget.
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) {
      if (_startAttempts++ < _maxStartAttempts) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _tryStartTour());
      } else {
        _tourPending = false; // give up; a fresh mount will retry next time
      }
      return;
    }
    _tourPending = false;
    _tourRunning = true;
    startFeatureTour();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<SettingsCubit, AppSettings>(
      // Replay edge: Settings flips the flag true→false to request a fresh run.
      listenWhen: (p, c) =>
          p.hasSeenFeatureShowcase && !c.hasSeenFeatureShowcase,
      listener: (_, _) => _queueTour(),
      child: RefreshIndicator(
        onRefresh: () => Future.wait([
          context.read<ServiceCubit>().refresh(),
          context.read<ContentCounterCubit>().refresh(),
        ]),
        child: ListView(
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.floatingNavClearance +
                MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            DashboardTopBar(onMenu: widget.onMenu),
            const SizedBox(height: AppSpacing.lg),
            const _Hero()
                .animate()
                .fadeIn(duration: AppDurations.normal)
                .slideY(begin: 0.08, end: 0),
            const SizedBox(height: AppSpacing.lg),
            const _ModeSection(),
            const SizedBox(height: AppSpacing.md),
            const _SessionBanners(),
            const ProtectionStatusCard(),
            const SizedBox(height: AppSpacing.md),
            const BlockerSection(),
          ],
        ),
      ),
    );
  }
}

/// The Command Center hero. Stateful so it can run a 1 Hz ticker while a Pause
/// session is live — the pause's remaining time decrements every second without
/// a cubit emit, so the card must tick itself. Conscious self-emits each second
/// (the native bank is pushed), so it rides the normal rebuild.
class _Hero extends StatefulWidget {
  const _Hero();

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Usage time advances between counted reels (the event stream only fires on
    // a count), so pull a fresh counter snapshot when the hero first mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<ContentCounterCubit>().refresh());
    });
  }

  void _syncTicker({required bool pauseLive}) {
    if (pauseLive && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!pauseLive && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final counter = context.watch<ContentCounterCubit>().state;
    final daily = context.watch<DailyLimitCubit>().state;
    final streak = context.watch<StreakCubit>().state;
    final now = DateTime.now();
    final pauseLive = settings.isPauseContractLive(now);
    _syncTicker(pauseLive: pauseLive);

    // Screen-time ring: today's usage in monitored social apps vs the user's
    // daily limit (set during onboarding). No limit → an unfilled gauge.
    final spent = counter.timeToday;
    final limit = daily.limit;
    final hasLimit = limit > Duration.zero;
    final progress = hasLimit
        ? (spent.inSeconds / limit.inSeconds).clamp(0.0, 1.0)
        : 0.0;
    final overLimit = hasLimit && spent >= limit;
    // Advance the "days under your daily limit" streak once today's under/over
    // status is known — post-frame so we don't emit during build.
    final underLimit = hasLimit && !overLimit;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<StreakCubit>().observe(now: now, underLimit: underLimit);
      }
    });
    final limitLabel = !hasLimit
        ? 'No daily limit set'
        : overLimit
        ? '${_formatHm(spent - limit)} over your ${_formatHm(limit)} limit'
        : 'of ${_formatHm(limit)}';

    SessionCountdown? countdown;
    if (pauseLive) {
      final session = settings.pauseSession!;
      final remaining = session.remainingIn(now);
      final total = session.phaseLengthAt(now).inMilliseconds;
      countdown = SessionCountdown(
        progress: total <= 0
            ? 0.0
            : (remaining.inMilliseconds / total).clamp(0.0, 1.0),
        remaining: remaining,
        caption: 'reels allowed',
        tone: AppTone.warning,
        icon: AppIcon.pause,
      );
    } else if (settings.activePlan == BlockingPlan.curious) {
      // select over watch: depend only on the four displayed fields, so a
      // Conscious emission that doesn't change what's shown no longer
      // rebuilds the hero.
      // ponytail: the 1 Hz display tick still rebuilds this build method —
      // the countdown is data in CommandCenterCard's API, not a widget slot.
      // Give it a slot if profiling ever shows the hero rebuild hurting.
      final c = context.select(
        (ConsciousCubit cubit) => (
          progress: cubit.state.progress,
          banked: cubit.state.banked,
          watching: cubit.state.watching,
          hasAllowance: cubit.state.hasAllowance,
        ),
      );
      countdown = SessionCountdown(
        progress: c.progress,
        remaining: c.banked,
        caption: c.watching
            ? 'spending'
            : (c.hasAllowance ? 'banked' : 'earning'),
      );
    }

    return CommandCenterCard(
      timeToday: _formatHm(spent),
      progress: progress,
      limitLabel: limitLabel,
      overLimit: overLimit,
      statusLabel: _statusLabel(settings, pauseLive: pauseLive),
      streakValue: '${streak.count}',
      reelsValue: '${counter.today}',
      countdown: countdown,
    );
  }
}

/// The vertical mode selector below the hero. Watches settings + the live reel
/// session; Block All / One Reel arm directly, Conscious / Pause open their glass
/// dialogs, Unblock confirms a count from its inline slider.
class _ModeSection extends StatelessWidget {
  const _ModeSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final reel = context.watch<ReelSessionCubit>().state;
    final pauseLive = settings.isPauseContractLive(DateTime.now());

    return ModeSelector(
      selected: _dashMode(settings, pauseLive: pauseLive),
      reelSession: reel,
      onSelect: (mode) => unawaited(_onModeSelect(context, mode)),
      // Spotlight each mode pill during the feature tour (indices align with
      // featureShowcaseSteps); identity when the tour isn't running.
      showcaseBuilder: (mode, child) {
        final i = switch (mode) {
          DashboardMode.blockAll => 0,
          DashboardMode.conscious => 1,
          DashboardMode.pause => 2,
          DashboardMode.oneReel => 3,
          DashboardMode.unblock => 4,
        };
        return showcaseTarget(
          step: featureShowcaseSteps[i],
          index: i,
          child: child,
        );
      },
    );
  }
}

/// Block All / One Reel arm directly; Conscious and Pause open their global glass
/// dialogs; Unblock is handled by the selector's inline slider (via onUnblock).
Future<void> _onModeSelect(BuildContext context, DashboardMode mode) async {
  switch (mode) {
    case DashboardMode.blockAll:
      await context.read<SettingsCubit>().setPlan(BlockingPlan.blockAll);
    case DashboardMode.oneReel:
      await context.read<SettingsCubit>().setOneReel(count: 1);
    case DashboardMode.unblock:
      await SessionDialogs.showUnblock(context);
    case DashboardMode.conscious:
      await SessionDialogs.showConscious(context);
    case DashboardMode.pause:
      await SessionDialogs.showPause(context);
  }
}

DashboardMode _dashMode(AppSettings s, {required bool pauseLive}) {
  if (pauseLive) return DashboardMode.pause;
  return switch (s.activePlan) {
    BlockingPlan.blockAll => DashboardMode.blockAll,
    BlockingPlan.curious => DashboardMode.conscious,
    BlockingPlan.oneReel =>
      s.reelAllowance <= 1 ? DashboardMode.oneReel : DashboardMode.unblock,
    BlockingPlan.paused => DashboardMode.pause,
  };
}

String _statusLabel(AppSettings settings, {required bool pauseLive}) {
  if (pauseLive) return 'PAUSED';
  return switch (settings.activePlan) {
    BlockingPlan.blockAll => 'BLOCK ALL',
    BlockingPlan.curious => 'CONSCIOUS',
    BlockingPlan.oneReel =>
      settings.reelAllowance <= 1 ? 'ONE REEL' : 'UNBLOCK',
    BlockingPlan.paused => 'PAUSED',
  };
}

/// "Xh Ym" (or "Ym" under an hour) for the screen-time value + limit sub-line.
String _formatHm(Duration d) {
  final total = d.inMinutes;
  final h = total ~/ 60;
  final m = total % 60;
  return h == 0 ? '${m}m' : '${h}h ${m}m';
}

/// Shown beneath the hero while a Pause or Curious contract is live. Owns a
/// 1 Hz ticker so the remaining time counts down (the cubit only emits on phase
/// changes, not every second).
class _SessionBanners extends StatefulWidget {
  const _SessionBanners();

  @override
  State<_SessionBanners> createState() => _SessionBannersState();
}

class _SessionBannersState extends State<_SessionBanners> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final now = DateTime.now();
    final banners = <Widget>[];

    if (settings.isPauseContractLive(now)) {
      final remaining = settings.pauseSession!.remainingIn(now);
      banners.add(
        _AnimatedActionTile(
          icon: AppIcon.pause,
          iconColor: AppColors.warning,
          title: 'Paused',
          // "Reels" not "all apps": whole-app locks hold through a Pause.
          subtitle: 'Reels allowed • ${formatCountdown(remaining)} left',
          onTap: () => unawaited(SessionDialogs.showPause(context)),
        ),
      );
    }

    if (settings.activePlan == BlockingPlan.curious) {
      // Own widget so the 1 Hz Conscious tick rebuilds ONLY this tile, not
      // the whole banners section.
      banners.add(const _ConsciousBanner());
    }

    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        children: [
          for (var i = 0; i < banners.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.xs),
            banners[i],
          ],
        ],
      ),
    );
  }
}

/// The Conscious session banner. Its own widget so the 1 Hz bank tick from
/// [ConsciousCubit] rebuilds only this tile, not the whole banners section.
class _ConsciousBanner extends StatelessWidget {
  const _ConsciousBanner();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ConsciousCubit>().state;
    final String title;
    final String subtitle;
    if (c.watching) {
      title = 'Conscious — spending';
      subtitle = 'Watching • ${formatCountdown(c.banked)} left';
    } else if (c.hasAllowance) {
      title = 'Conscious — ready';
      subtitle = '${formatCountdown(c.banked)} banked • open reels to spend';
    } else {
      title = 'Conscious — earning';
      subtitle = 'Reels blocked • earn ${SessionDefaults.consciousEarnLabel}';
    }
    return _AnimatedActionTile(
      icon: AppIcon.shieldCheck,
      title: title,
      subtitle: subtitle,
      onTap: () => unawaited(SessionDialogs.showConscious(context)),
    );
  }
}

/// A [GlassListTile] whose leading glyph morphs on appear and replays on every
/// tap. The tile (via `AppPressable`) owns the gesture, so the icon is
/// controller-driven.
class _AnimatedActionTile extends StatefulWidget {
  const _AnimatedActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.iconColor,
  });

  final AppIcon icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  State<_AnimatedActionTile> createState() => _AnimatedActionTileState();
}

class _AnimatedActionTileState extends State<_AnimatedActionTile> {
  final AnimatedIconController _controller = AnimatedIconController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTap() {
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _controller
        ..reset()
        ..animate();
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GlassListTile(
      leading: AppAnimatedIcon(
        icon: widget.icon,
        size: 24,
        color: widget.iconColor ?? Theme.of(context).colorScheme.secondary,
        controller: _controller,
        playOnAppear: true,
      ),
      title: widget.title,
      subtitle: widget.subtitle,
      trailing: const Icon(Icons.chevron_right),
      onTap: _onTap,
    );
  }
}
