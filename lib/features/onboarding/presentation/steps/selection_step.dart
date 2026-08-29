import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/presentation/onboarding_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Pick the feeds to protect. Requires at least one — a first run that ends
/// with nothing selected has produced nothing.
///
/// Renders through the blocklist's own [BlockAppTile] / [BlockAppGroup], so
/// Instagram's Feed / Reels / Stories collapse under one tile here exactly as
/// they do on the blocklist screen, and the two can never drift apart.
class SelectionStep extends StatefulWidget {
  const SelectionStep({required this.progress, super.key});

  final OnboardingProgress progress;

  /// Only installed apps. Showing feeds the user cannot open would make the
  /// "pick at least one" gate answerable with something that blocks nothing.
  static List<BlockTarget> installedOf(List<BlockTarget> all) =>
      all.where((t) => t.isInstalled).toList();

  /// The scan finished and found nothing to protect. The walker reads this to
  /// unlock Next: "pick at least one" cannot be a requirement when there is
  /// nothing to pick, or the run can never be completed on this device.
  static bool nothingToPick(TargetsState state) =>
      !state.isLoading && installedOf(state.targets).isEmpty;

  @override
  State<SelectionStep> createState() => _SelectionStepState();
}

class _SelectionStepState extends State<SelectionStep> {
  bool _seeded = false;

  /// One-shot: entering this step with no picks yet inherits the set the splash
  /// already seeded from each installed target's `defaultEnabled`. Re-runs on a
  /// resume straight into this step, which is the behaviour we want — an empty
  /// selection is never a state worth restoring.
  void _seed(List<BlockTarget> installed) {
    if (_seeded || widget.progress.platforms.isNotEmpty) return;
    _seeded = true;
    final defaults = installed
        .where((t) => t.defaultEnabled)
        .map((t) => t.platformId)
        .toSet();
    if (defaults.isEmpty) return;
    // Post-frame: this runs from a builder, and setPlatforms emits.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<OnboardingCubit>().setPlatforms(defaults);
    });
  }

  void _toggle(String platformId, {required bool enabled}) {
    final next = {...widget.progress.platforms};
    if (enabled) {
      next.add(platformId);
    } else {
      next.remove(platformId);
    }
    context.read<OnboardingCubit>().setPlatforms(next);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return BlocBuilder<TargetsCubit, TargetsState>(
      builder: (context, state) {
        final installed = SelectionStep.installedOf(state.targets);
        if (installed.isEmpty) {
          // `isLoading` is the ONLY spinner condition. A successful scan that
          // finds nothing has `isLoading: false, error: null`, so keying the
          // spinner off `error == null` left that user watching "Finding your
          // apps…" forever with Next disabled and Skip gone — onboarding could
          // never be completed, on this or any later launch.
          return Center(
            child: state.isLoading
                ? const LoadingState(message: 'Finding your apps…')
                : EmptyState(
                    icon: Icons.apps_rounded,
                    title: state.error == null
                        ? 'Nothing to protect yet'
                        : 'Could not read your apps',
                    subtitle: state.error == null
                        ? 'None of the apps Detoxo guards are installed. '
                              'Install one and it shows up here — or add feeds '
                              'later from the blocklist.'
                        : 'Detoxo could not read your installed apps. You can '
                              'pick feeds later from the blocklist.',
                  ),
          );
        }
        _seed(installed);
        final picked = widget.progress.platforms;
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            96,
            AppSpacing.lg,
            168,
          ),
          children: [
            Text(
              'What should Detoxo guard?',
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Only the endless feeds — the rest of each app keeps working. '
              'Change this any time.',
              style: text.bodyMedium?.copyWith(
                color: context.glass.onGlassMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            for (final group in BlockAppGroup.from(installed))
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: BlockAppTile(
                  group: group,
                  enabledIds: picked,
                  onToggle: _toggle,
                ),
              ),
          ],
        );
      },
    );
  }
}
