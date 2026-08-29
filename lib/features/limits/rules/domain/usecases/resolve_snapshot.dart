import 'package:detoxo/features/catalog/catalog.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule_snapshot.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/rule_calendar.dart';

/// Floor for a *projected* limit exhaustion. The projection assumes the target
/// app keeps running, so as a budget nears zero it lands arbitrarily close to
/// `now`; arming the resync timer (and native's boundary) there spins a
/// query + resolve + push cycle until midnight whenever the app is NOT in fact
/// being used, because `used` never moves. Real window edges stay exact — only
/// the guess is floored.
const int _minProjectionMs = 60 * 1000;

/// The pushed snapshot plus what each rule is doing right now.
class RulesEvaluation {
  const RulesEvaluation(this.snapshot, this.statuses);

  final RulesSnapshot snapshot;

  /// Keyed by rule id; disabled rules map to [RuleStatus.off].
  final Map<String, RuleStatus> statuses;
}

/// Turns stored rules into the flat snapshot native enforces. Pure: the clock,
/// today's usage and the catalog are all arguments.
///
/// - Rules are evaluated in `createdAtMs` order — native takes the FIRST
///   blocking entry, so order is the tie-break.
/// - A schedule contributes every window in the next [horizonDays] days
///   (absolute, device zone); a rule with none is omitted.
/// - A limit always contributes an entry for today's whole period, carrying its
///   budget and whether that budget is spent; native blocks only on a SPENT one
///   and re-measures the PENDING ones itself (EVO-029). Unspent time limits also
///   contribute their projected exhaustion to the boundary. With [usageKnown]
///   false nothing is newly spent, but an entry already blocking stays.
/// - [dailyReelLimit] > 0 appends the synthetic daily reel limit entry, metered
///   natively against today's reel time.
/// - [activeOverrides] (M8) maps a rule id to the window an override has bought
///   on it. That window is SUBTRACTED from the entry's own windows, so the rule
///   stops blocking for exactly that stretch and native re-arms at the far edge
///   by the long compare it already does — no wire field, no Kotlin, and the
///   lift stays scoped to the one rule the user paid for rather than to its
///   targets (which would also free every sibling rule and the App Blocker row
///   for the same app).
///
/// ponytail: device zone only — windows are resolved at push time, so a
/// timezone change is honoured at the next re-push (resume / boundary).
///
/// ponytail: a projected exhaustion is floored at [_minProjectionMs], so a
/// Dart-side flip can be up to a minute late. Enforcement no longer depends on
/// it — EVO-029 has native re-measure the same budgets at the watchdog tick —
/// so this now only paces how quickly the UI catches up.
RulesEvaluation resolveSnapshot({
  required List<Rule> rules,
  required DateTime now,
  Map<String, int> usageMsByPackage = const {},
  Map<String, int> opensByPackage = const {},
  bool usageKnown = false,
  Duration dailyReelLimit = Duration.zero,
  Catalog? catalog,
  int horizonDays = 7,
  List<SnapshotEntry> previousEntries = const [],
  Map<String, TimeWindow> activeOverrides = const {},
}) {
  final cat = catalog ?? Catalog.bundled;
  final nowMs = now.millisecondsSinceEpoch;
  final (dayStart, dayEnd) = todayInterval(now);
  final today = TimeWindow(
    dayStart.millisecondsSinceEpoch,
    dayEnd.millisecondsSinceEpoch,
  );
  final entries = <SnapshotEntry>[];
  final statuses = <String, RuleStatus>{};
  var boundary = 0;
  void consider(int t) {
    if (t > nowMs && (boundary == 0 || t < boundary)) boundary = t;
  }

  // `packagesWithBehavior` is SCANNED, not indexed, and its own doc says it is
  // called once per config push — "not per rule per resolve". `_lockWiden`
  // needs it twice (packages, then domains) for every locked rule, so it is
  // resolved at most once here, and only if some rule actually asks.
  List<String>? distractingMemo;
  List<String> distracting() =>
      distractingMemo ??= cat.packagesWithBehavior(AppBehavior.distracting);

  final ordered = [...rules]
    ..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
  for (final r in ordered) {
    if (!r.enabled) {
      statuses[r.id] = RuleStatus.off;
      continue;
    }
    final targets = _flatten(r.selection, cat);
    // M8: the window an active override has bought on THIS rule, subtracted
    // from whatever it would otherwise block. `consider` re-arms the boundary
    // at the far edge so the UI and native both come back exactly then.
    final lift = activeOverrides[r.id];
    if (lift != null) consider(lift.endMs);
    switch (r.kind) {
      case RuleKind.schedule:
        final s = r.schedule;
        final windows = s == null
            ? const <TimeWindow>[]
            : scheduleWindows(s, now, horizonDays: horizonDays);
        TimeWindow? open;
        TimeWindow? next;
        for (final w in windows) {
          consider(w.startMs);
          consider(w.endMs);
          if (w.contains(nowMs)) open ??= w;
          if (w.startMs > nowMs) next ??= w;
        }
        // The status the UI renders is what is ACTUALLY enforced. "Lifted"
        // means the lift is suppressing something: with no open window there
        // was nothing to suppress, and calling that Lifted would both lie and
        // hide the real next change.
        final lifted = lift != null && lift.contains(nowMs) && open != null;
        statuses[r.id] = RuleStatus(
          activeNow: open != null && !lifted,
          liftedUntilMs: lifted ? lift.endMs : 0,
          nextChangeMs: lifted
              ? lift.endMs
              : (open?.endMs ?? next?.startMs ?? 0),
        );
        final pushed = lift == null
            ? windows
            : subtractWindow(windows, lift.startMs, lift.endMs);
        if (pushed.isNotEmpty) {
          entries.add(
            SnapshotEntry(
              id: r.id,
              reason: SnapshotEntry.reasonSchedule,
              mode: r.selection.mode,
              // The lock scope widens what the rule COVERS. Applied here, at
              // entry construction — never inside `_flatten`, whose package
              // list is also the budget denominator for a limit rule.
              packages: _lockWiden(
                r,
                targets.packages,
                cat,
                _WidenKind.packages,
                distracting,
              ),
              domains: _lockWiden(
                r,
                targets.domains,
                cat,
                _WidenKind.domains,
                distracting,
              ),
              platformIds: targets.platformIds,
              windows: pushed,
              strict: r.isStrict,
            ),
          );
        }
      case RuleKind.timeLimit:
        final used = _sum(usageMsByPackage, targets.packages);
        final spent = usageKnown
            ? r.thresholdMs > 0 && used >= r.thresholdMs
            : _wasSpent(previousEntries, r.id, nowMs, lift);
        consider(today.endMs);
        if (r.thresholdMs > 0) {
          entries.add(_limitEntry(r, targets, today, spent: spent, lift: lift));
        }
        if (!spent && usageKnown && r.thresholdMs > used) {
          final remaining = r.thresholdMs - used;
          consider(
            nowMs +
                (remaining < _minProjectionMs ? _minProjectionMs : remaining),
          );
        }
        final lifted = lift != null && lift.contains(nowMs) && spent;
        statuses[r.id] = RuleStatus(
          activeNow: spent && !lifted,
          spent: spent,
          liftedUntilMs: lifted ? lift.endMs : 0,
          usedMs: used,
          usageKnown: usageKnown,
          nextChangeMs: lifted ? lift.endMs : (spent ? today.endMs : 0),
        );
      case RuleKind.openLimit:
        final opens = _sum(opensByPackage, targets.packages);
        final spent = usageKnown
            ? r.maxOpens > 0 && opens >= r.maxOpens
            : _wasSpent(previousEntries, r.id, nowMs, lift);
        consider(today.endMs);
        if (r.maxOpens > 0) {
          entries.add(_limitEntry(r, targets, today, spent: spent, lift: lift));
        }
        final lifted = lift != null && lift.contains(nowMs) && spent;
        statuses[r.id] = RuleStatus(
          activeNow: spent && !lifted,
          spent: spent,
          liftedUntilMs: lifted ? lift.endMs : 0,
          opens: opens,
          usageKnown: usageKnown,
          nextChangeMs: lifted ? lift.endMs : (spent ? today.endMs : 0),
        );
    }
  }
  if (dailyReelLimit > Duration.zero) {
    entries.add(
      SnapshotEntry(
        id: SnapshotEntry.dailyReelLimitId,
        reason: SnapshotEntry.reasonDailyLimit,
        platformIds: const [SnapshotEntry.allPlatforms],
        always: true,
        reelTimeLimitMs: dailyReelLimit.inMilliseconds,
      ),
    );
    consider(today.endMs);
  }
  return RulesEvaluation(
    // The boundary stands on its own: a snapshot can be all-pending (nothing
    // blocking yet) and still need native and the timer to come back when a
    // budget runs out.
    RulesSnapshot(entries: entries, nextBoundaryMs: boundary),
    statuses,
  );
}

class _Targets {
  const _Targets(this.packages, this.domains, this.platformIds);
  final List<String> packages;
  final List<String> domains;
  final List<String> platformIds;
}

/// Removes `[from, until)` from [windows], splitting any window it lands inside
/// (M8's override).
///
/// A schedule 09:00–17:00 with a lift 10:00–11:00 becomes
/// `[[09:00,10:00],[11:00,17:00]]`. Native needs no change at all —
/// `RuleEngine.Entry.isActive` already walks a flat pair array — and it re-arms
/// at 11:00 by its own long compare, so the lift ends on time with Flutter
/// dead. That is the property a Dart-side "skip this rule" flag would lose.
List<TimeWindow> subtractWindow(List<TimeWindow> windows, int from, int until) {
  if (until <= from) return windows;
  final out = <TimeWindow>[];
  for (final w in windows) {
    // Disjoint: keep it whole.
    if (until <= w.startMs || from >= w.endMs) {
      out.add(w);
      continue;
    }
    // The head that survives before the lift, and the tail after it. Either
    // can be empty (a lift that covers the window entirely removes it).
    if (w.startMs < from) out.add(TimeWindow(w.startMs, from));
    if (until < w.endMs) out.add(TimeWindow(until, w.endMs));
  }
  return out;
}

enum _WidenKind { packages, domains }

/// `lockScope: DISTRACTING` — every package the catalog marks distracting (and
/// their domains) on top of the rule's own selection, so the lock keeps holding
/// as new apps are installed.
///
/// Three gates, each of which is the difference between a feature and a bug:
/// - **`locked` only.** It is a lock scope, not a selection mode.
/// - **`SCHEDULE` only.** For a TIME_LIMIT / OPEN_LIMIT the package list is
///   also the BUDGET denominator (`_sum` below, and native's `LimitReconciler`
///   sums across the same set) — widening would turn "30 minutes of Instagram"
///   into "30 minutes of any distracting app", spent within minutes.
/// - **`BLOCK` only.** Under `ALL_EXCEPT` membership is inverted, so adding
///   these packages would make them the only apps EXEMPT from the rule — the
///   exact opposite of locking. The editor emits BLOCK today, but ALL_EXCEPT is
///   carried end to end for a later focus mode, so this is a live trap.
List<String> _lockWiden(
  Rule r,
  List<String> base,
  Catalog cat,
  _WidenKind kind,
  List<String> Function() distracting,
) {
  if (!r.locked ||
      r.lockScope != LockScope.distracting ||
      r.kind != RuleKind.schedule ||
      r.selection.mode != SelectionMode.block) {
    return base;
  }
  final out = <String>{...base};
  for (final pkg in distracting()) {
    if (kind == _WidenKind.packages) {
      out.add(pkg);
    } else {
      out.addAll(cat.domainsForPackage(pkg));
    }
  }
  out.remove('');
  return out.toList();
}

/// Categories become their services' packages AND domains (a category is "the
/// service"); an explicitly picked app stays app-only, like the App Blocker.
_Targets _flatten(RuleSelection sel, Catalog cat) {
  final packages = <String>{...sel.apps};
  final domains = <String>{
    for (final w in sel.websites) Catalog.normalizeHost(w),
  };
  for (final id in sel.categories) {
    for (final pkg in cat.packagesIn(id)) {
      packages.add(pkg);
      domains.addAll(cat.domainsForPackage(pkg));
    }
  }
  domains.remove('');
  return _Targets(
    packages.toList(),
    domains.toList(),
    List<String>.from(sel.platforms),
  );
}

/// Whether [id] was already enforcing in the last snapshot. Usage can fail
/// transiently (a `USAGE_QUERY_FAILED` from the platform) or permanently (the
/// user revokes Usage Access) — either way the next push would otherwise drop
/// a limit entry that is already blocking, so a spent budget could be lifted
/// mid-day, and revoking the grant would be a one-step unlock. Unknown usage
/// still never *starts* a block: this only holds one that is already up.
///
/// [lift] is the override that is currently holding this rule open, if any. The
/// previous snapshot has the lift's window CUT OUT of it, so probing `nowMs`
/// while the lift is running would find no covering window and read as "not
/// spent" — the budget would silently un-spend, and (with usage still unknown)
/// stay un-spent after the lift ended. Probing the instant *before* the lift
/// began asks the question the window test was actually for: was this budget
/// already gone today?
bool _wasSpent(
  List<SnapshotEntry> previous,
  String id,
  int nowMs,
  TimeWindow? lift,
) {
  final at = lift != null && lift.contains(nowMs) ? lift.startMs - 1 : nowMs;
  for (final e in previous) {
    if (e.id != id || !e.spent) continue;
    for (final w in e.windows) {
      if (w.contains(at)) return true;
    }
  }
  return false;
}

int _sum(Map<String, int> byPackage, List<String> packages) {
  var total = 0;
  for (final p in packages) {
    total += byPackage[p] ?? 0;
  }
  return total;
}

/// A limit entry, spent or pending. Anchored to the current period rather than
/// to "now", so a re-push a minute later is byte-identical.
///
/// EVO-029: a PENDING entry ([spent] false) rides the wire too — it carries the
/// budget so native can re-measure it at the watchdog tick and flip it while
/// Detoxo is closed. Native never blocks on a pending entry.
///
/// M8: an active override subtracts its window from today's period rather than
/// forcing `spent: false`. Flipping the flag would hand the entry back to
/// native's watchdog reconciler (EVO-029), which measures pending budgets and
/// would simply re-close the override within 15 minutes.
SnapshotEntry _limitEntry(
  Rule r,
  _Targets t,
  TimeWindow today, {
  required bool spent,
  TimeWindow? lift,
}) {
  // A time limit whose targets are FEEDS rather than apps has nothing for
  // UsageStats to meter: `_sum` runs over packages, so it measured 0 forever
  // and the rule could never become spent — while `platformIds` was dropped
  // here too, so it covered nothing either. Both halves had to be wrong for the
  // rule to be silently inert, and onboarding's starter rule is exactly this
  // shape for four of six survey answers, including "skip".
  //
  // Native already meters reel time for the global Daily Limit, keyed on this
  // exact entry shape (platformIds + reelTimeLimitMs), and it does so with
  // Detoxo closed. So the same shape expresses "30 minutes of reels a day" for
  // one rule, with no Kotlin change: `isMeteredLimit` covers only the budgets
  // Dart measures, so a reel-metered entry is never treated as pending.
  final reelMetered =
      r.kind == RuleKind.timeLimit &&
      t.packages.isEmpty &&
      t.platformIds.isNotEmpty;
  return SnapshotEntry(
    id: r.id,
    reason: SnapshotEntry.reasonDailyLimit,
    mode: r.selection.mode,
    packages: t.packages,
    // A category flattens to its packages AND its domains ("a category is the
    // service"), so a spent limit on one has to close the websites too —
    // dropping them blocked the app and left the browser wide open, which is not
    // what the editor promises. Platforms ride along for the same reason.
    domains: t.domains,
    platformIds: t.platformIds,
    windows: lift == null
        ? [today]
        : subtractWindow([today], lift.startMs, lift.endMs),
    strict: r.isStrict,
    usageLimitMs: r.kind == RuleKind.timeLimit && !reelMetered
        ? r.thresholdMs
        : 0,
    reelTimeLimitMs: reelMetered ? r.thresholdMs : 0,
    openLimitCount: r.kind == RuleKind.openLimit ? r.maxOpens : 0,
    spent: spent,
  );
}
