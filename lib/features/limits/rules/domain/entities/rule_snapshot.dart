import 'dart:convert';

import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:equatable/equatable.dart';

/// An absolute `[startMs, endMs)` window in epoch milliseconds.
class TimeWindow extends Equatable {
  const TimeWindow(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  bool contains(int t) => t >= startMs && t < endMs;

  List<int> toJson() => [startMs, endMs];

  @override
  List<Object?> get props => [startMs, endMs];
}

/// One resolved rule as the native `RuleEngine` sees it: flat target lists and
/// absolute windows — no calendar, no categories, nothing to parse on the hot
/// path beyond two long compares and a set lookup. MIRROR CONTRACT with
/// `engine/RuleEngine.kt` (`parse`).
class SnapshotEntry extends Equatable {
  const SnapshotEntry({
    required this.id,
    required this.reason,
    this.mode = SelectionMode.block,
    this.packages = const [],
    this.domains = const [],
    this.platformIds = const [],
    this.windows = const [],
    this.always = false,
    this.reelTimeLimitMs = 0,
    this.strict = false,
    this.usageLimitMs = 0,
    this.openLimitCount = 0,
    this.spent = false,
  });

  /// `blockReason` tokens the wall already renders ("Blocked by a schedule" /
  /// "Your daily limit is used up").
  static const String reasonSchedule = 'SCHEDULE';
  static const String reasonDailyLimit = 'DAILY_LIMIT';

  /// Wildcard `platformId` — every reel surface.
  static const String allPlatforms = '*';

  /// The synthetic entry that enforces the global Daily Limit natively.
  static const String dailyReelLimitId = 'daily_reel_limit';

  final String id;
  final String reason;
  final SelectionMode mode;
  final List<String> packages;
  final List<String> domains;
  final List<String> platformIds;

  /// Sorted, non-overlapping. Ignored when [always] is true.
  final List<TimeWindow> windows;

  /// True → active regardless of [windows] (the daily reel limit entry).
  final bool always;

  /// `> 0` → native meter: the entry blocks its platforms once today's reel
  /// time (`ContentCounterStore.timeTodayMs`) reaches this.
  final int reelTimeLimitMs;

  /// EVO-030: enforced ABOVE the pause gate — a Pause does not lift it.
  final bool strict;

  /// EVO-029: the rule's own daily budget, so native can re-measure it at the
  /// watchdog tick instead of waiting for Dart to run. `0` = not a time limit.
  final int usageLimitMs;

  /// EVO-029: the rule's daily launch allowance. `0` = not an open limit.
  final int openLimitCount;

  /// Whether the budget above is already used up. An entry with a budget and
  /// [spent] false is PENDING: native measures it but does not block on it.
  final bool spent;

  Map<String, dynamic> toJson() => {
    'id': id,
    'reason': reason,
    'mode': mode.wire,
    'packages': packages,
    'domains': domains,
    'platformIds': platformIds,
    'windows': [for (final w in windows) w.toJson()],
    'always': always,
    'reelTimeLimitMs': reelTimeLimitMs,
    'strict': strict,
    'usageLimitMs': usageLimitMs,
    'openLimitCount': openLimitCount,
    'spent': spent,
  };

  @override
  List<Object?> get props => [
    id,
    reason,
    mode,
    packages,
    domains,
    platformIds,
    windows,
    always,
    reelTimeLimitMs,
    strict,
    usageLimitMs,
    openLimitCount,
    spent,
  ];
}

/// What crosses the wire on `pushRules`.
class RulesSnapshot extends Equatable {
  const RulesSnapshot({this.entries = const [], this.nextBoundaryMs = 0});

  final List<SnapshotEntry> entries;

  /// The earliest moment any window opens or closes (or a limit is projected
  /// to run out); `0` when there is nothing to wait for.
  final int nextBoundaryMs;

  String toJsonString() => jsonEncode([for (final e in entries) e.toJson()]);

  @override
  List<Object?> get props => [entries, nextBoundaryMs];
}

/// What the UI shows for one rule right now.
class RuleStatus extends Equatable {
  const RuleStatus({
    this.activeNow = false,
    this.spent = false,
    this.usedMs = 0,
    this.opens = 0,
    this.usageKnown = true,
    this.nextChangeMs = 0,
    this.liftedUntilMs = 0,
  });

  /// A disabled rule.
  static const RuleStatus off = RuleStatus();

  /// Blocking right now (an open schedule window or a spent limit).
  final bool activeNow;

  /// A limit whose budget is used up for today.
  final bool spent;

  /// Foreground time consumed today against a time limit.
  final int usedMs;

  /// Launches counted today against an open limit.
  final int opens;

  /// False when UsageStats could not be read — a limit then shows "needs
  /// usage access" rather than a confident zero.
  final bool usageKnown;

  /// When [activeNow] flips next (window edge, or midnight for a spent
  /// limit); `0` = nothing scheduled.
  final int nextChangeMs;

  /// M8: an override is holding this rule open until this moment; `0` = none.
  /// [activeNow] is already false while it runs, so the tile can say "Lifted
  /// until 5:30 PM" instead of claiming the rule is enforcing.
  final int liftedUntilMs;

  bool get isLifted => liftedUntilMs > 0;

  /// Whether this rule is actually holding something shut right now — an open
  /// schedule window, or a limit whose budget is gone. The predicate an
  /// override has to satisfy to be worth spending (`UnblockQuota.validateOverride`
  /// takes it as `enforcingNow`), so it lives here rather than being spelled
  /// out at each call site in the editor.
  bool get enforcing => activeNow || spent;

  @override
  List<Object?> get props => [
    activeNow,
    spent,
    usedMs,
    opens,
    usageKnown,
    nextChangeMs,
    liftedUntilMs,
  ];
}
