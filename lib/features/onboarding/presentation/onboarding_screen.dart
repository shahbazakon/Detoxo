import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/services/firebase/firebase.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/domain/repositories/onboarding_repository.dart';
import 'package:detoxo/features/onboarding/domain/starter_rule.dart';
import 'package:detoxo/features/onboarding/presentation/onboarding_cubit.dart';
import 'package:detoxo/features/onboarding/presentation/steps/projection_step.dart';
import 'package:detoxo/features/onboarding/presentation/steps/selection_step.dart';
import 'package:detoxo/features/onboarding/presentation/steps/survey_step.dart';
import 'package:detoxo/features/onboarding/presentation/widgets/caught_hero.dart';
import 'package:detoxo/features/onboarding/presentation/widgets/commitment_hero.dart';
import 'package:detoxo/features/onboarding/presentation/widgets/screen_time_dial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// The first run: a linear, persisted step machine over the ambient gradient.
///
/// The machine itself is [OnboardingCubit]; this screen is the walker that
/// renders whatever step the cubit is on. Because every step lives inside this
/// one route, resuming is a single read — there is no partial navigation stack
/// to rebuild, and a kill at any point comes back exactly where it left off.
///
/// The last step hands off to the real [Routes.permissions] screen rather than
/// re-implementing it: that screen already owns the Play prominent-disclosure
/// dialogs, the restricted-settings recovery sheet and the unknown-state
/// handling. The starter rule is written later still, by `StarterRuleSync`,
/// when accessibility is actually granted.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => OnboardingCubit(
        sl<OnboardingRepository>(),
        onStep: (step, direction) => sl<AnalyticsService>().logOnboardingStep(
          step.wire,
          direction: direction.wire,
        ),
      )..load(),
      child: const _OnboardingWalker(),
    );
  }
}

class _OnboardingWalker extends StatelessWidget {
  const _OnboardingWalker();

  /// Accent per step — the existing three-colour arc, kept.
  static Color _accent(OnboardingStepId step) => switch (step) {
    OnboardingStepId.welcome || OnboardingStepId.survey => AppColors.seed,
    OnboardingStepId.projection ||
    OnboardingStepId.selection => AppColors.onbTeal,
    _ => AppColors.onbViolet,
  };

  /// Whether Next is available. Only two steps gate: the survey needs its
  /// required answers, and the selection needs at least one feed — unless there
  /// is nothing to pick, which must not be a dead end (a device with none of
  /// the supported apps installed could otherwise never finish onboarding, and
  /// so could never leave this screen on any future launch either).
  static bool _canAdvance(OnboardingProgress p, TargetsState targets) =>
      switch (p.step) {
        OnboardingStepId.survey => SurveyStep.isComplete(p),
        OnboardingStepId.selection =>
          p.platforms.isNotEmpty || SelectionStep.nothingToPick(targets),
        _ => true,
      };

  /// Skip jumps to the selection — the first step that produces something.
  /// It disappears from there on: neither the picks nor the permissions are
  /// skippable, because without them onboarding has protected nothing.
  static bool _canSkip(OnboardingStepId step) =>
      step.index < OnboardingStepId.selection.index;

  Future<void> _next(BuildContext context, OnboardingProgress p) async {
    final cubit = context.read<OnboardingCubit>();
    AppHaptics.selection();

    // Leaving the selection: push the picks into the real enabled set so the
    // native engine enforces exactly what the user just chose.
    if (p.step == OnboardingStepId.selection) {
      await context.read<SettingsCubit>().setEnabledPlatforms(p.platforms);
    }

    // `permissions` is where the walker ends. Reaching it — or RESUMING onto it
    // after a crash between `advance` and `setOnboarded` — means re-running the
    // hand-off. Without this the resumed state renders an enabled button that
    // does nothing, on a screen the user cannot tell they already passed.
    if (p.step.index >= OnboardingStepId.permissions.index ||
        cubit.nextStep == OnboardingStepId.permissions) {
      if (context.mounted) await _handOff(context, p);
      return;
    }
    final next = cubit.nextStep;
    if (next == null) return;
    await cubit.advance(next);
  }

  /// The commitment → permissions hand-off, in an order that matters.
  ///
  /// `onboarded` flips HERE, not at grant time: a user who quits on the
  /// permission screen has already answered everything, and making them replay
  /// the whole funnel to get back to a system settings toggle is the worst
  /// version of this flow. The progress record keeps `step: permissions`, which
  /// is what still arms the starter rule for the moment accessibility is
  /// granted.
  ///
  /// So the record is advanced BEFORE the flag: flipping `onboarded` notifies
  /// `AppGate` and the router redirects away on the spot, and a crash in the
  /// gap must leave an armed record rather than a user who is onboarded with
  /// nothing waiting to be created.
  Future<void> _handOff(BuildContext context, OnboardingProgress p) async {
    final cubit = context.read<OnboardingCubit>();
    final settings = context.read<SettingsCubit>();
    final dailyLimit = context.read<DailyLimitCubit>();
    final router = GoRouter.of(context);
    AppHaptics.success();
    await dailyLimit.setLimit(Duration(minutes: p.dailyLimitMinutes));
    await cubit.advance(OnboardingStepId.permissions);
    // Through the cubit, not the repository: the barrel now exports it, so the
    // old raw-repo write (and the splash round-trip that stopped a stale cubit
    // state from clobbering the flag on the next commit) is gone.
    await settings.setOnboarded(value: true);
    // Belt and braces: the gate's redirect lands on the same place by itself,
    // but this keeps the hand-off working on its own if the listener is ever
    // rewired.
    router.go(Routes.permissions);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OnboardingCubit, OnboardingProgress>(
      builder: (context, p) {
        final cubit = context.read<OnboardingCubit>();
        final accent = _accent(p.step);
        final back = cubit.previousStep;
        // Watched, not read: the selection step's Next unlocks when the target
        // scan comes back empty, so the CTA has to rebuild when it lands.
        final targets = context.watch<TargetsCubit>().state;
        final isLast = p.step.index >= OnboardingStepId.commitment.index;
        return PopScope(
          // Back at the first step must not drop the user out of the app
          // mid-onboarding; elsewhere it walks the machine backwards.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && back != null) cubit.advance(back);
          },
          child: GlassScaffold(
            safeArea: false,
            body: Stack(
              children: [
                AnimatedSwitcher(
                  duration: AppDurations.normal,
                  switchInCurve: AppCurves.decelerate,
                  child: KeyedSubtree(
                    key: ValueKey(p.step),
                    child: _step(p, accent),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: AnimatedOpacity(
                      duration: AppDurations.fast,
                      opacity: _canSkip(p.step) ? 1 : 0,
                      child: GhostButton(
                        label: 'Skip',
                        onPressed: _canSkip(p.step)
                            ? () => cubit.advance(OnboardingStepId.selection)
                            : null,
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: AnimatedOpacity(
                      duration: AppDurations.fast,
                      opacity: back == null ? 0 : 1,
                      child: GhostButton(
                        label: 'Back',
                        onPressed: back == null
                            ? null
                            : () => cubit.advance(back),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xl,
                        0,
                        AppSpacing.xl,
                        AppSpacing.xl,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ProgressBar(step: p.step, accent: accent),
                          const SizedBox(height: AppSpacing.lg),
                          PrimaryButton(
                            label: isLast ? 'Get started' : 'Next',
                            tint: accent,
                            expand: true,
                            onPressed: _canAdvance(p, targets)
                                ? () => _next(context, p)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _step(OnboardingProgress p, Color accent) => switch (p.step) {
    OnboardingStepId.welcome => _HeroStep(
      accent: accent,
      hero: CaughtHero(accent: accent),
      title: 'Take your time back',
      body:
          'You didn’t decide to watch 80 reels — the feed did. Detoxo spots '
          'them the second they play and pulls you back out, right inside the '
          'apps you already use.',
      footer: const Padding(
        padding: EdgeInsets.only(top: AppSpacing.lg),
        child: Center(
          child: Pill(
            label: 'Blocks the reels, not the app',
            tone: AppTone.accent,
          ),
        ),
      ),
    ),
    OnboardingStepId.survey => SurveyStep(progress: p),
    OnboardingStepId.projection => ProjectionStep(progress: p, accent: accent),
    OnboardingStepId.selection => SelectionStep(progress: p),
    // `permissions` and `completed` are hand-off states, not screens — but the
    // record advances to `permissions` a beat before the redirect fires, so
    // holding the last real step here keeps that beat from flashing blank.
    _ => _CommitmentStep(progress: p, accent: accent),
  };
}

/// Segmented filling progress bar — clearer completion cue than dots.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.step, required this.accent});

  final OnboardingStepId step;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // The permissions step is walked on its own screen, so the bar counts the
    // steps this walker actually renders.
    const steps = OnboardingStepId.visible;
    final count = steps.length - 1;
    // `permissions` is walked on its own screen and `completed` is terminal;
    // both mean "the last rendered step". `indexOf(completed)` is -1, which a
    // bare clamp would report as "Step 1 of 5" while the last step is on screen.
    final index = switch (step) {
      OnboardingStepId.permissions || OnboardingStepId.completed => count - 1,
      _ => steps.indexOf(step).clamp(0, count - 1),
    };
    return Semantics(
      container: true,
      label: 'Step ${index + 1} of $count',
      child: Row(
        children: List.generate(count, (i) {
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: i == count - 1 ? 0 : AppSpacing.xs,
              ),
              child: AnimatedContainer(
                duration: AppDurations.normal,
                curve: AppCurves.standard,
                height: 6,
                decoration: BoxDecoration(
                  color: i <= index ? accent : context.glass.border,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// A coded hero, headline and body — the shape the informational steps share.
class _HeroStep extends StatelessWidget {
  const _HeroStep({
    required this.accent,
    required this.hero,
    required this.title,
    required this.body,
    this.footer,
  });

  final Color accent;
  final Widget hero;
  final String title;
  final String body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 96, AppSpacing.xl, 168),
      child: ListView(
        children: [
          hero,
          const SizedBox(height: AppSpacing.xxl),
          Text(
            title,
            textAlign: TextAlign.center,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ).animate().fadeIn(delay: 80.ms).slideY(begin: 0.15, end: 0),
          const SizedBox(height: AppSpacing.md),
          Text(
            body,
            textAlign: TextAlign.center,
            style: text.bodyLarge?.copyWith(color: context.glass.onGlass),
          ).animate().fadeIn(delay: 160.ms).slideY(begin: 0.15, end: 0),
          ?footer,
        ],
      ),
    );
  }
}

/// The last walked step: what the user is committing to, in their own terms,
/// plus the daily-limit dial (kept from the old page-four step).
class _CommitmentStep extends StatelessWidget {
  const _CommitmentStep({required this.progress, required this.accent});

  final OnboardingProgress progress;
  final Color accent;

  /// The promise, rendered FROM the preset that `starterRule` will actually
  /// stamp — not restated in prose. The hours already live in `RulePreset`, and
  /// `starter_rule.dart` exists precisely so there is one copy of them; writing
  /// "22:00" here again would be a third, in the one place no test asserts it.
  String get _promise {
    final template = starterPreset(progress.mattersMost).template;
    final schedule = template.schedule;
    if (schedule == null) {
      final minutes = template.thresholdMs ~/ 60000;
      return '$minutes minutes of feed a day. After that the feeds you picked '
          'stop opening until tomorrow.';
    }
    final when = schedule.days.length == 7 ? 'Every day' : 'Weekdays';
    return '$when from ${RuleSchedule.formatHHmm(schedule.startMin)}, the '
        'feeds you picked stop opening — until '
        '${RuleSchedule.formatHHmm(schedule.endMin)}.';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = progress.name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 72, AppSpacing.lg, 158),
      child: ListView(
        children: [
          CommitmentHero(accent: accent),
          const SizedBox(height: AppSpacing.xl),
          Text(
            name == null ? 'Here’s the deal' : 'Here’s the deal, $name',
            textAlign: TextAlign.center,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _promise,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: context.glass.onGlass),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'And a daily ceiling for everything else:',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: context.glass.onGlassMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: ScreenTimeDial(
              value: Duration(minutes: progress.dailyLimitMinutes),
              onChanged: context.read<OnboardingCubit>().setDailyLimit,
              accent: accent,
              size: 220,
            ),
          ),
        ],
      ),
    );
  }
}
