import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/domain/onboarding_script.dart';
import 'package:detoxo/features/onboarding/domain/repositories/onboarding_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The first run as a linear, persisted step machine. Three properties carry
/// the whole design:
///
/// 1. **Persist before navigating.** The machine lives inside ONE route, so
///    "navigate" is an `emit` — `await save` then `emit` gets the ordering for
///    free, with no partial route stack to restore. A crash between the two
///    resumes at the *next* step, a harmless replay; the reverse order loses it.
/// 2. **Write each answer as it is given**, never batched. Batching at the end
///    means a user who abandons at the last question is a user whose answers
///    never existed.
/// 3. The starter rule is NOT created here — see `lib/app/starter_rule_sync.dart`.
///    It is written the moment enforcement becomes possible (accessibility
///    granted), not the moment the feeds are picked.
/// How a step was arrived at. Wire tokens: a funnel that cannot tell a Back tap
/// from a Next tap cannot measure drop-off.
enum StepDirection {
  /// First render of the run, or a resume onto a saved step.
  enter('ENTER'),
  forward('FORWARD'),
  back('BACK');

  const StepDirection(this.wire);

  final String wire;
}

class OnboardingCubit extends Cubit<OnboardingProgress> {
  OnboardingCubit(this._repo, {this.onStep})
    : super(const OnboardingProgress());

  final OnboardingRepository _repo;

  /// Funnel hook (analytics). Fires per step change, never per answer.
  ///
  /// The direction separates a Back tap from a Next tap — they are the same
  /// `advance` call, so without it every step total is inflated by an unknown
  /// number of backward visits.
  final void Function(OnboardingStepId step, StepDirection direction)? onStep;

  /// RESUME, always — never restart. Called once when the screen mounts.
  Future<void> load() async {
    final saved = await _repo.load();
    if (isClosed) return;
    // Stamp the start time on the very first entry so the record always has
    // one, even if the user never answers anything.
    emit(
      saved.startedAtMs == 0
          ? saved.copyWith(startedAtMs: DateTime.now().millisecondsSinceEpoch)
          : saved,
    );
    // The entry event. Without it the first step never fires — the funnel's
    // first recorded step would be whatever the user advanced TO, leaving
    // welcome→survey drop-off with no denominator.
    onStep?.call(state.step, StepDirection.enter);
  }

  /// Writes one survey answer. [value] is a wire token for chips, raw text for
  /// the name; null clears it. An unknown field is ignored rather than thrown —
  /// the script is data, and a typo there must not crash the first run.
  Future<void> answer(String field, String? value) => _write(switch (field) {
    fieldName => state.copyWith(
      name: value?.trim(),
      clearName: value == null || value.trim().isEmpty,
    ),
    fieldBand => state.copyWith(band: ScreenTimeBand.fromWire(value)),
    fieldMattersMost => state.copyWith(
      mattersMost: MattersMost.fromWire(value),
    ),
    _ => state,
  });

  Future<void> setPlatforms(Set<String> platforms) =>
      _write(state.copyWith(platforms: platforms));

  Future<void> setDailyLimit(Duration limit) =>
      _write(state.copyWith(dailyLimitMinutes: limit.inMinutes));

  /// Persist the next step, THEN emit it. Also the Back path — hence the
  /// direction handed to [onStep].
  Future<void> advance(OnboardingStepId next) async {
    if (next == state.step) return;
    final backward = next.index < state.step.index;
    await _write(state.copyWith(step: next));
    onStep?.call(next, backward ? StepDirection.back : StepDirection.forward);
  }

  /// The step before the current one in [OnboardingStepId.visible], or null on the
  /// first one. Back is pure navigation — it never erases an answer.
  OnboardingStepId? get previousStep {
    final i = OnboardingStepId.visible.indexOf(state.step);
    return i <= 0 ? null : OnboardingStepId.visible[i - 1];
  }

  OnboardingStepId? get nextStep {
    final i = OnboardingStepId.visible.indexOf(state.step);
    return i < 0 || i == OnboardingStepId.visible.length - 1
        ? null
        : OnboardingStepId.visible[i + 1];
  }

  Future<void> _write(OnboardingProgress next) async {
    if (next == state) return;
    await _repo.save(next);
    if (!isClosed) emit(next);
  }
}
