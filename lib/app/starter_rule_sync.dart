import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/onboarding/onboarding.dart';
import 'package:detoxo/features/permissions/permissions.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

/// What the progress record says should happen the next time the app is in a
/// position to write the starter rule. Pure, so the decision is testable
/// without a widget tree or a channel.
@visibleForTesting
enum StarterRuleAction {
  /// Not onboarding's window — an existing install, or a run still in progress.
  none,

  /// A record left behind by a crash between marking `completed` and clearing
  /// it. The rule already exists; the record is dead weight holding the user's
  /// name in Hive, so drop it.
  clearOrphan,

  /// The window: the walk finished, enforcement just became possible.
  write,
}

@visibleForTesting
StarterRuleAction starterRuleAction(OnboardingProgress progress) =>
    switch (progress.step) {
      OnboardingStepId.permissions => StarterRuleAction.write,
      OnboardingStepId.completed => StarterRuleAction.clearOrphan,
      _ => StarterRuleAction.none,
    };

/// Reads the record and, if this is onboarding's window, writes the starter
/// rule and consumes the record.
///
/// Split out of the widget and given its collaborators as parameters so the
/// decisions below — which are the whole point of the feature — are testable
/// without a widget tree, a channel or a service locator.
///
/// [save] is `RulesCubit.save` in production: it validates, enforces the
/// 50-rule cap and resyncs the snapshot to native in one step, and returns
/// false when it refuses. [isMounted] reports whether the caller is still alive.
///
/// Never throws: this runs behind the app's first real screen.
@visibleForTesting
Future<void> applyStarterRule({
  required OnboardingRepository repo,
  required Future<bool> Function(Rule rule) save,
  required bool Function() isMounted,
}) async {
  try {
    final progress = await repo.load();
    switch (starterRuleAction(progress)) {
      case StarterRuleAction.none:
        return;
      case StarterRuleAction.clearOrphan:
        await repo.clear();
        return;
      case StarterRuleAction.write:
        break;
    }
    // Disposed mid-await (teardown, hot restart). Leave the record ARMED —
    // this is "try again later", not "job done", so it must NOT fall through to
    // the consume below the way a completed write does. It used to share the
    // condition with the data guards, which meant an unmounted teardown ate the
    // record and the rule could never be written on any later launch.
    if (!isMounted()) return;

    if (progress.platforms.isNotEmpty) {
      final rule = starterRule(
        // Null only when the survey was skipped; `starterRule` maps that to the
        // same budget the commitment screen promised.
        mattersMost: progress.mattersMost,
        platforms: progress.platforms,
        id: const Uuid().v4(),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (!await save(rule)) {
        // `.e`, not `.w`: this is the one outcome the whole funnel exists to
        // prevent — granted, onboarded, and no rule — and `.w` is debug-only,
        // so it would be invisible in release.
        AppLogger.e('starter rule rejected — leaving onboarding armed');
        return;
      }
    }
    // Resume state, and its job is done.
    await repo.clear();
  } on Object catch (e, s) {
    AppLogger.e('starter rule sync failed', e, s);
  }
}

/// Writes the first run's starter rule the moment enforcement becomes possible.
///
/// **Why not at selection time.** A rule written when the user picks their feeds
/// does nothing for however long they hesitate on the accessibility screen —
/// and nothing forever if they never grant it. Writing it here means the first
/// thing that happens after granting is that Detoxo actually does something.
///
/// **Why two listeners and no edge detector.** Nothing pushes an "accessibility
/// granted" signal: the state is read, not delivered. It would be natural to
/// watch the false→true edge on `allRequiredGranted` — and that is exactly what
/// this used to do, and it was wrong. `PermissionsCubit.effectivelyGranted`
/// consults `_lastKnownGranted`, which `refresh()` overwrites *before* it
/// emits, so re-evaluating the PREVIOUS state inside `listenWhen` scores it
/// against post-refresh memory: a previous emit holding a live `unknown` for an
/// already-persisted permission reads back as granted, `!true` collapses the
/// edge, and the rule is silently never written. Reading a level instead of an
/// edge cannot go wrong that way, and the write itself is idempotent, so firing
/// often is free.
///
/// The second listener closes a cold-start race: the grant can be discovered by
/// the bootstrap's own `permissions.refresh()` while `RulesCubit` is still
/// loading, and `RulesCubit.save` refuses to write on top of rules it has not
/// read yet. Waiting for `loaded` costs nothing and keeps `rules.load` off the
/// startup critical path.
///
/// Mounted app-wide rather than on the permission screen so a grant made from
/// anywhere still arms the rule.
class StarterRuleSync extends StatefulWidget {
  const StarterRuleSync({required this.child, super.key});

  final Widget child;

  @override
  State<StarterRuleSync> createState() => _StarterRuleSyncState();
}

class _StarterRuleSyncState extends State<StarterRuleSync> {
  /// Re-entry guard: both listeners can fire in the same frame.
  bool _writing = false;

  /// Runs only when the app could actually honour a write. Both preconditions
  /// are levels, not edges, so a missed notification is picked up by the next.
  void _maybeRun(BuildContext context) {
    if (!context.read<PermissionsCubit>().allRequiredGranted) return;
    if (!context.read<RulesCubit>().state.loaded) return;
    _onGranted(context.read<RulesCubit>());
  }

  Future<void> _onGranted(RulesCubit rules) async {
    if (_writing) return;
    _writing = true;
    try {
      await applyStarterRule(
        repo: sl<OnboardingRepository>(),
        save: rules.save,
        isMounted: () => mounted,
      );
    } finally {
      _writing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<PermissionsCubit, List<PermissionStatus>>(
          listener: (context, _) => _maybeRun(context),
        ),
        BlocListener<RulesCubit, RulesState>(
          listenWhen: (a, b) => !a.loaded && b.loaded,
          listener: (context, _) => _maybeRun(context),
        ),
      ],
      child: widget.child,
    );
  }
}
