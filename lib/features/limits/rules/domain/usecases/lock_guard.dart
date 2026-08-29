import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';

/// The locked-rule invariant, enforced in the DOMAIN layer (M8).
///
/// > the UI must not expose enable/disable/delete for a locked rule. Any
/// > mutation attempt is rejected in the domain layer, not the UI only.
///
/// Hiding the toggle is not enough: `RulesCubit` is reachable from other
/// features (the dashboard card, the resume sync, the splash reload), and a
/// rule that can be disabled through a side door is not locked. So this runs on
/// the ONE choke point every mutation funnels through — `RulesCubit._commit` —
/// rather than on `save` / `remove` / `setEnabled` separately, which is both a
/// smaller diff and impossible to forget on a fourth mutation added later.
///
/// Returns the user-facing refusal, or null when the change is allowed.
abstract final class LockGuard {
  /// What a locked rule refuses.
  ///
  /// - **Deleting** it.
  /// - **Disabling** it.
  /// - **Unlocking** it — there is no in-app unlock at all; see [Rule.locked].
  /// - **Narrowing** its targets, which is deleting it one app at a time.
  /// - **Weakening** it: a looser budget, or any change to its schedule.
  ///
  /// That last one matters as much as the others. A lock whose *targets* are
  /// frozen but whose schedule can be moved to 03:00–03:01, or whose 30-minute
  /// budget can be dragged to 240, is not locked — it is neutered in two taps,
  /// for free, without spending an override. Widening the hours would be a
  /// legitimate want, but distinguishing "wider" from "narrower" across
  /// overnight windows and day sets is real containment arithmetic for a rare
  /// case; refusing every schedule change is the smaller, safer rule.
  ///
  /// What it still allows: renaming, and WIDENING the selection or the lock
  /// scope. Tightening a commitment is never the thing you regret at 1 a.m.
  static String? check(List<Rule> previous, List<Rule> next) {
    if (previous.isEmpty) return null;
    final after = {for (final r in next) r.id: r};
    for (final before in previous) {
      if (!before.locked) continue;
      final now = after[before.id];
      if (now == null) return deleteRefused;
      if (!now.enabled) return disableRefused;
      if (!now.locked) return unlockRefused;
      if (_narrows(before.selection, now.selection)) return narrowRefused;
      if (before.lockScope == LockScope.distracting &&
          now.lockScope != LockScope.distracting) {
        return narrowRefused;
      }
      if (before.schedule != now.schedule) return scheduleRefused;
      // A rule re-saved as a different KIND is a rewrite wearing the old id:
      // the dimensions this guard froze stop meaning anything, and the ones the
      // new kind reads were never checked.
      if (before.kind != now.kind) return kindRefused;
      // A BIGGER budget is a weaker rule: more minutes, more launches.
      if (now.thresholdMs > before.thresholdMs) return budgetRefused;
      if (now.maxOpens > before.maxOpens) return budgetRefused;
      // …and so is a budget of NOTHING. `resolveSnapshot` emits no entry at
      // all for a limit at zero, so tightening to zero silently disables the
      // rule while travelling the one direction this guard waves through.
      // Unreachable from today's editor (the sliders floor above zero); held
      // here because this is billed as the choke point every caller inherits.
      if (before.thresholdMs > 0 && now.thresholdMs <= 0) return budgetRefused;
      if (before.maxOpens > 0 && now.maxOpens <= 0) return budgetRefused;
    }
    return null;
  }

  /// Whether any dimension lost a target. Set-based, so reordering the same
  /// targets is not a narrowing.
  static bool _narrows(RuleSelection before, RuleSelection after) =>
      !after.platforms.toSet().containsAll(before.platforms) ||
      !after.apps.toSet().containsAll(before.apps) ||
      !after.websites.toSet().containsAll(before.websites) ||
      !after.categories.toSet().containsAll(before.categories) ||
      // Flipping BLOCK → ALL_EXCEPT inverts what the rule covers, which frees
      // every target it named. That is a narrowing wearing a different hat.
      before.mode != after.mode;

  static const String deleteRefused =
      'This rule is locked. It can be lifted for a while with an override, but '
      'not deleted.';
  static const String disableRefused =
      'This rule is locked. Use an override to lift it for a while.';
  static const String unlockRefused =
      'A locked rule cannot be unlocked. That was the point when you made it.';
  static const String narrowRefused =
      'A locked rule can be widened, never narrowed.';
  static const String scheduleRefused =
      "A locked rule's hours are fixed. Use an override to get through once.";
  static const String budgetRefused =
      "A locked rule's limit can be tightened, never loosened — and never to "
      'nothing.';
  static const String kindRefused =
      'A locked rule cannot be turned into a different kind of rule.';
}
