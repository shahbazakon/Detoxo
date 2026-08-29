import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/conscious_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/session_defaults.dart';
import 'package:detoxo/features/blocking/plans/presentation/conscious_cubit.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/countdown_ring.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sleek_circular_slider/sleek_circular_slider.dart';

/// The single global surface for the Pause and Conscious modes — opened as a
/// frosted [GlassDialog] from the dashboard so the whole app shares one modal
/// style instead of dedicated full screens. Each dialog is dual-state: it sets
/// the mode up when idle and offers the live action (Resume / Turn off) while a
/// session runs. The live countdown itself lives in the dashboard hero ring.
abstract final class SessionDialogs {
  static Future<void> showPause(BuildContext context) =>
      GlassDialog.show<void>(context: context, child: const _PauseDialog());

  static Future<void> showConscious(BuildContext context) =>
      GlassDialog.show<void>(context: context, child: const _ConsciousDialog());

  static Future<void> showUnblock(BuildContext context) =>
      GlassDialog.show<void>(context: context, child: const _UnblockDialog());
}

// ── Unblock (allow N reels, then revert to the base mode) ────────────────────

class _UnblockDialog extends StatefulWidget {
  const _UnblockDialog();

  @override
  State<_UnblockDialog> createState() => _UnblockDialogState();
}

class _UnblockDialogState extends State<_UnblockDialog> {
  int _count = SessionDefaults.unblockDefault;

  void _unlock() {
    context.read<SettingsCubit>().setOneReel(count: _count);
    Navigator.of(context).pop();
  }

  /// The base mode this Unblock will return to when the count is spent.
  String get _baseLabel =>
      planLabel(context.read<SettingsCubit>().state.baseMode);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Unblock',
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: SleekCircularSlider(
            min: SessionDefaults.unblockSliderMin.toDouble(),
            max: SessionDefaults.unblockSliderMax.toDouble(),
            initialValue: SessionDefaults.unblockDefault.toDouble(),
            appearance: pauseSliderAppearance(context, interactive: true),
            onChange: (value) {
              final n = SessionDefaults.snapUnblockCount(value);
              if (n != _count) setState(() => _count = n);
            },
            innerWidget: (_) => _sliderCenter(context),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Watch a set number of reels',
          textAlign: TextAlign.center,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'You can watch $_count reels, then blocking returns automatically '
          'to $_baseLabel.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: context.glass.onGlassMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        PrimaryButton(
          label: 'Unlock $_count reels',
          expand: true,
          onPressed: _unlock,
        ),
      ],
    );
  }

  Widget _sliderCenter(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppAnimatedIcon(
          icon: AppIcon.unblock,
          size: 40,
          color: Theme.of(context).colorScheme.secondary,
          playOnAppear: true,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '$_count',
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
        Text(
          _count == 1 ? 'reel' : 'reels',
          style: text.labelSmall?.copyWith(
            color: context.glass.onGlassMuted,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

// ── Pause ───────────────────────────────────────────────────────────────────

class _PauseDialog extends StatefulWidget {
  const _PauseDialog();

  @override
  State<_PauseDialog> createState() => _PauseDialogState();
}

class _PauseDialogState extends State<_PauseDialog> {
  int _minutes = SessionDefaults.pauseDefaultMinutes;

  void _start() {
    context.read<SettingsCubit>().startPause(
      pause: Duration(minutes: _minutes),
    );
    Navigator.of(context).pop();
  }

  void _resume() {
    context.read<SettingsCubit>().resumeNow();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      builder: (context, settings) => settings.isPauseContractLive()
          ? _liveView(context)
          : _pickerView(context),
    );
  }

  Widget _pickerView(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pause',
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: SleekCircularSlider(
            min: SessionDefaults.pauseSliderMin.toDouble(),
            max: SessionDefaults.pauseSliderMax.toDouble(),
            initialValue: SessionDefaults.pauseDefaultMinutes.toDouble(),
            appearance: pauseSliderAppearance(context, interactive: true),
            onChange: (value) {
              final m = SessionDefaults.snapPauseMinutes(value);
              if (m != _minutes) setState(() => _minutes = m);
            },
            innerWidget: (_) => _sliderCenter(context),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Take a mindful pause',
          textAlign: TextAlign.center,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Reels and blocked sites are allowed for $_minutes min, then '
          'Block All resumes automatically. App locks stay on.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: context.glass.onGlassMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        PrimaryButton(label: 'Start pause', expand: true, onPressed: _start),
      ],
    );
  }

  Widget _sliderCenter(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppAnimatedIcon(
          icon: AppIcon.pause,
          size: 44,
          color: Theme.of(context).colorScheme.secondary,
          playOnAppear: true,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '$_minutes',
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
        Text(
          'min',
          style: text.labelSmall?.copyWith(
            color: context.glass.onGlassMuted,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }

  Widget _liveView(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.pause_circle_outline,
          size: 44,
          color: AppColors.warning,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Pause active',
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Reels and blocked sites are allowed; app locks stay on. Blocking '
          'resumes automatically when the window ends.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: context.glass.onGlassMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        SecondaryButton(
          label: 'Resume blocking now',
          expand: true,
          onPressed: _resume,
        ),
      ],
    );
  }
}

// ── Conscious ─────────────────────────────────────────────────────────────────

class _ConsciousDialog extends StatelessWidget {
  const _ConsciousDialog();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      buildWhen: (a, b) => a.activePlan != b.activePlan,
      builder: (context, settings) {
        final on = settings.activePlan == BlockingPlan.curious;
        return on ? const _ConsciousLive() : const _ConsciousIntro();
      },
    );
  }
}

class _ConsciousIntro extends StatelessWidget {
  const _ConsciousIntro();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cap = SessionDefaults.consciousMaxBank.inMinutes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Icon(
            Icons.self_improvement,
            size: 44,
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Conscious mode',
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Earn reel time by staying off it.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: context.glass.onGlassMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          title: 'How it works',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Bullet('Reels stay blocked while you abstain.'),
              const _Bullet(
                'Every ${SessionDefaults.consciousEarnDivisor} min blocked '
                'banks 1 min of allowance.',
              ),
              _Bullet('Unused time collects, up to $cap min.'),
              const _Bullet(
                'Open reels to spend it — when the bank empties, blocking '
                'returns automatically.',
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        PrimaryButton(
          label: 'Turn on Conscious',
          expand: true,
          onPressed: () {
            context.read<SettingsCubit>().enterConscious();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

class _ConsciousLive extends StatelessWidget {
  const _ConsciousLive();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cap = SessionDefaults.consciousMaxBank.inMinutes;

    return BlocBuilder<ConsciousCubit, ConsciousState>(
      builder: (context, state) {
        final String headline;
        final String hint;
        if (state.watching) {
          headline = 'Watching — spending';
          hint =
              'Your banked time is draining. Step away to start earning '
              'again.';
        } else if (state.hasAllowance) {
          headline = 'Banked allowance';
          hint =
              'Open reels to spend it. Earns '
              '${SessionDefaults.consciousEarnLabel} while you abstain.';
        } else {
          headline = 'Earn to watch';
          hint =
              'Abstain to bank time: ${SessionDefaults.consciousEarnLabel}, '
              'up to $cap min.';
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Icon(
                Icons.shield_outlined,
                size: 44,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              headline,
              textAlign: TextAlign.center,
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${formatCountdown(state.banked)} banked · cap $cap:00',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: context.glass.onGlassMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(
                color: context.glass.onGlassMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            GhostButton(
              label: 'Turn off Conscious',
              onPressed: () {
                context.read<SettingsCubit>().stopConscious();
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: AppSpacing.sm),
            child: Icon(
              Icons.circle,
              size: 6,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
