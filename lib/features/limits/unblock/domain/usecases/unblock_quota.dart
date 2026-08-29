import 'package:detoxo/features/limits/unblock/domain/entities/bypass_config.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_entry.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';

/// Pure functions over the two M8 stores. Static and clock-injected — the
/// `StreakCubit.advance` pattern — so every rule here is testable without a
/// widget, a repository or a platform channel.
abstract final class UnblockQuota {
  /// Grants that are live right now, newest first.
  static List<TemporaryUnblock> activeAt(
    List<TemporaryUnblock> grants,
    int nowMs,
  ) => [
    for (final g in grants)
      if (g.isActiveAt(nowMs)) g,
  ];

  /// Drops cancelled and finished grants, then caps the list.
  ///
  /// Pruning happens on WRITE, never on read: an unbounded list inside a single
  /// JSON document is a slow leak, and a read-time prune would make two readers
  /// disagree about what is stored.
  static List<TemporaryUnblock> prune(
    List<TemporaryUnblock> grants,
    int nowMs,
  ) {
    final live = [
      for (final g in grants)
        if (!g.isSpentAt(nowMs)) g,
    ]..sort((a, b) => b.startMs.compareTo(a.startMs));
    return live.length <= maxTemporaryUnblocks
        ? live
        : live.sublist(0, maxTemporaryUnblocks);
  }

  /// The earliest moment an active grant ends, or 0 when none is live. Drives
  /// the cubit's one-shot timer, so a countdown clears itself.
  static int nextExpiryMs(List<TemporaryUnblock> grants, int nowMs) {
    var soonest = 0;
    for (final g in grants) {
      if (!g.isActiveAt(nowMs)) continue;
      if (soonest == 0 || g.endMs < soonest) soonest = g.endMs;
    }
    return soonest;
  }

  /// Whether [grants] already covers this exact target — so a second tap
  /// extends rather than stacks.
  static TemporaryUnblock? activeFor(
    List<TemporaryUnblock> grants,
    UnblockTargetType type,
    String id,
    int nowMs,
  ) {
    for (final g in grants) {
      if (g.targetType == type && g.targetId == id && g.isActiveAt(nowMs)) {
        return g;
      }
    }
    return null;
  }

  // ── The override quota ──────────────────────────────────────────────────

  /// Overrides left in the current period.
  ///
  /// A **rolling** window: an entry counts while it is younger than
  /// `config.periodMs`. Not a calendar week — that needs week-start, timezone
  /// and DST arithmetic for no gain, and it makes a clock jump MORE rewarding
  /// (one hop past the boundary refills the whole quota, instead of ageing out
  /// one entry). It is also the shape M2.2's emergency-pass cooldown already
  /// specifies for this same ledger, so the store has one clock story.
  ///
  /// ponytail: wall-clock. Moving the system clock forward mints quota — the
  /// ceiling already accepted at `pin_config.dart` (reboot + clock-forward) and
  /// in `WebBlockEngine`. Not worth hardening here alone: the same jump already
  /// walks the user out of every schedule window and resets every daily budget,
  /// which is a far bigger prize than two hours of override. Harden at that
  /// shared `now`, once, or not at all.
  static int effectiveRemaining(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) {
    final used = _countedInPeriod(entries, config, nowMs).length;
    final left = config.overrideLimit - used;
    return left > 0 ? left : 0;
  }

  /// When the next override comes back, or 0 while some are still available.
  /// The OLDEST counted entry is the one that ages out first.
  static int resetsAtMs(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) {
    final counted = _countedInPeriod(entries, config, nowMs);
    if (counted.length < config.overrideLimit) return 0;
    var oldest = counted.first.atMs;
    for (final e in counted) {
      if (e.atMs < oldest) oldest = e.atMs;
    }
    return oldest + config.periodMs;
  }

  static bool canOverride(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) => effectiveRemaining(entries, config, nowMs) > 0;

  /// The live lift for [ruleId], or null. Read by the snapshot resolver, so a
  /// locked rule's own windows can be split around it.
  static BypassEntry? activeOverrideFor(
    List<BypassEntry> entries,
    String ruleId,
    int nowMs,
  ) {
    for (final e in entries) {
      if (e.kind == BypassKind.override &&
          e.ruleId == ruleId &&
          e.isLiftActiveAt(nowMs)) {
        return e;
      }
    }
    return null;
  }

  /// Every live lift, keyed by rule id — one pass for the resolver.
  static Map<String, BypassEntry> activeOverrides(
    List<BypassEntry> entries,
    int nowMs,
  ) {
    final out = <String, BypassEntry>{};
    for (final e in entries) {
      final id = e.ruleId;
      if (e.kind != BypassKind.override || id == null) continue;
      if (!e.isLiftActiveAt(nowMs)) continue;
      // Newest wins if two ever overlap on one rule.
      final held = out[id];
      if (held == null || e.atMs > held.atMs) out[id] = e;
    }
    return out;
  }

  /// Why [startMs]–[endMs] cannot be granted for a rule, or null when it can.
  ///
  /// Every check runs BEFORE anything is written — a refusal must never leave a
  /// half-spent quota behind, so the cheapest wrong-shaped request must not be
  /// able to burn one either.
  ///
  /// [enforcingNow] is whether the rule is *actually blocking* at this instant.
  /// It is checked FIRST and deliberately: an override buys a window starting
  /// now, so spending one on a schedule that is closed (or a limit whose budget
  /// is not spent) costs a scarce resource and lifts nothing. The rule was
  /// simply going to let you in anyway.
  static String? validateOverride({
    required List<BypassEntry> entries,
    required BypassConfig config,
    required OverrideReason? reason,
    required int startMs,
    required int endMs,
    required int nowMs,
    bool enforcingNow = true,
  }) {
    if (!enforcingNow) return notBlockingNow;
    if (!canOverride(entries, config, nowMs)) return noOverridesLeft;
    if (reason == null) return reasonRequired;
    if (endMs <= startMs) return windowInverted;
    if (endMs - startMs > config.overrideMaxWindowMs) return windowTooLong;
    return null;
  }

  /// Prunes the ledger to its cap, newest first — **per kind**.
  ///
  /// Per kind and not overall, since EVO-053 records grants in the same store:
  /// a burst of grants would otherwise evict override rows that are still
  /// inside their 7-day window, and an evicted row is a refunded override. The
  /// cap exists to bound a document, not to referee between two budgets.
  static List<BypassEntry> pruneLedger(List<BypassEntry> entries) {
    final sorted = [...entries]..sort((a, b) => b.atMs.compareTo(a.atMs));
    final kept = <BypassKind, int>{};
    return [
      for (final e in sorted)
        if ((kept[e.kind] = (kept[e.kind] ?? 0) + 1) <= maxBypassEntries) e,
    ];
  }

  static const String notBlockingNow =
      "That rule isn't blocking right now — you don't need an override.";
  static const String noOverridesLeft = 'No overrides left this week.';
  static const String reasonRequired = 'Pick a reason first.';
  static const String windowInverted = 'That window ends before it starts.';
  static const String windowTooLong = 'That is longer than an override allows.';

  static List<BypassEntry> _countedInPeriod(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) => _inPeriod(entries, BypassKind.override, config.periodMs, nowMs);

  static List<BypassEntry> _inPeriod(
    List<BypassEntry> entries,
    BypassKind kind,
    int periodMs,
    int nowMs,
  ) => [
    for (final e in entries)
      // A future-stamped row (a clock that moved backwards after it was
      // written) still counts: `nowMs - atMs` is negative, which is younger
      // than the period, so it is not silently forgiven.
      if (e.kind == kind && nowMs - e.atMs < periodMs) e,
  ];

  // ── EVO-053: the grant budget ───────────────────────────────────────────

  /// Per-target unblocks left in the current period, or **null when grants are
  /// not rationed** (`grantLimit == 0`, the default).
  ///
  /// Null rather than a large number on purpose: "unlimited" and "plenty left"
  /// are different sentences, and the UI must not render a countdown for a
  /// budget nobody set.
  ///
  /// Same rolling window and the same clock ceiling as the override quota
  /// above — one arithmetic, two budgets, so there is never a second story
  /// about when a period ends.
  static int? grantsRemaining(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) {
    if (!config.grantsRationed) return null;
    final used = _inPeriod(
      entries,
      BypassKind.grant,
      config.grantPeriodMs,
      nowMs,
    ).length;
    final left = config.grantLimit - used;
    return left > 0 ? left : 0;
  }

  /// When the grant budget refills, or 0 while some are left / not rationed.
  static int grantsResetAtMs(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) {
    if (!config.grantsRationed) return 0;
    final counted = _inPeriod(
      entries,
      BypassKind.grant,
      config.grantPeriodMs,
      nowMs,
    );
    if (counted.length < config.grantLimit) return 0;
    var oldest = counted.first.atMs;
    for (final e in counted) {
      if (e.atMs < oldest) oldest = e.atMs;
    }
    return oldest + config.grantPeriodMs;
  }

  // ── EVO-052: what the ledger can say back ───────────────────────────────

  /// Overrides spent in the current period and the reasons given, newest
  /// first. Derived every time, never stored — the entries ARE the record.
  ///
  /// The point of the reason picker is that naming it costs something; a reason
  /// written to disk and never shown again is a diary nobody keeps.
  static ({int count, List<OverrideReason> reasons}) overrideSummary(
    List<BypassEntry> entries,
    BypassConfig config,
    int nowMs,
  ) {
    final counted = _countedInPeriod(entries, config, nowMs);
    return (
      count: counted.length,
      reasons: [
        for (final e in counted)
          if (e.reason != null) e.reason!,
      ],
    );
  }
}
