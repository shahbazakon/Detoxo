import 'package:equatable/equatable.dart';

/// Hard cap on stored rules: the native engine iterates the pushed snapshot
/// per accessibility event, so the list must stay small.
const int maxRules = 50;

/// What a rule does once it applies. The wire strings are a storage contract —
/// a rename is a migration.
enum RuleKind {
  /// Block the targets during a weekly time window.
  schedule('SCHEDULE'),

  /// Block the targets until midnight once a daily foreground-time budget is
  /// spent.
  timeLimit('TIME_LIMIT'),

  /// Block the targets until midnight after N launches in a day.
  openLimit('OPEN_LIMIT');

  const RuleKind(this.wire);

  final String wire;

  /// Null for an unknown token so the caller can drop the document instead of
  /// guessing what it was meant to do.
  static RuleKind? fromWire(String? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }

  /// Limits are metered from UsageStats; a schedule is pure calendar.
  bool get isLimit => this != RuleKind.schedule;

  String get label => switch (this) {
    RuleKind.schedule => 'Schedule',
    RuleKind.timeLimit => 'Daily time limit',
    RuleKind.openLimit => 'Open limit',
  };
}

/// How the selection is read: block what is listed, or everything except it.
/// The editor emits [block] only; [allExcept] rides the wire and is enforced
/// natively so a later "focus mode" is a UI change, not a contract change.
enum SelectionMode {
  block('BLOCK'),
  allExcept('ALL_EXCEPT');

  const SelectionMode(this.wire);

  final String wire;

  static SelectionMode fromWire(String? v) =>
      v == allExcept.wire ? allExcept : block;
}

/// What a rule targets. Categories are flattened to packages + domains at push
/// time through the catalog; [platforms] are reel surfaces (`platformId`s).
class RuleSelection extends Equatable {
  const RuleSelection({
    this.mode = SelectionMode.block,
    this.platforms = const [],
    this.apps = const [],
    this.websites = const [],
    this.categories = const [],
  });

  factory RuleSelection.fromJson(Map<String, dynamic> m) => RuleSelection(
    mode: SelectionMode.fromWire(_str(m['type'])),
    platforms: _strings(m['platforms']),
    apps: _strings(m['apps']),
    websites: _strings(m['websites']),
    categories: _strings(m['categories']),
  );

  final SelectionMode mode;
  final List<String> platforms;
  final List<String> apps;
  final List<String> websites;
  final List<String> categories;

  bool get isEmpty =>
      platforms.isEmpty &&
      apps.isEmpty &&
      websites.isEmpty &&
      categories.isEmpty;

  Map<String, dynamic> toJson() => {
    'type': mode.wire,
    'platforms': platforms,
    'apps': apps,
    'websites': websites,
    'categories': categories,
  };

  @override
  List<Object?> get props => [mode, platforms, apps, websites, categories];
}

/// How wide a lock reaches (M8). A stable name string; the default survives a
/// document written before locks existed.
enum LockScope {
  /// Exactly the rule's own selection.
  selection('SELECTION'),

  /// Every package the catalog marks `distracting`, plus their domains — so
  /// the lock keeps holding as new apps are installed. Resolved at snapshot
  /// time, and only for a `SCHEDULE` rule in `BLOCK` mode (see
  /// `resolveSnapshot`): widening a time or open limit would silently widen its
  /// BUDGET too, and widening an `ALL_EXCEPT` rule inverts it.
  ///
  /// ponytail: the catalog is a bundled static seed, so an app released after
  /// the last build is `neutral` and this misses it as well. It widens today's
  /// coverage; it does not future-proof it.
  distracting('DISTRACTING');

  const LockScope(this.wire);

  final String wire;

  static LockScope fromWire(String? v) =>
      v == distracting.wire ? distracting : selection;
}

/// A weekly window. [startMin] / [endMin] are minutes after local midnight;
/// `endMin < startMin` is an overnight window ("22:00 → 06:00") whose morning
/// slice still belongs to the START day. `startMin == endMin` never matches —
/// the editor refuses it.
class RuleSchedule extends Equatable {
  const RuleSchedule({
    required this.days,
    required this.startMin,
    required this.endMin,
  });

  factory RuleSchedule.fromJson(Map<String, dynamic> m) => RuleSchedule(
    days: {
      for (final d in _list(m['repeatDays']))
        if (d is num && d >= 1 && d <= 7) d.toInt(),
    },
    startMin: parseHHmm(_str(m['timeStart'])),
    endMin: parseHHmm(_str(m['timeEnd'])),
  );

  static const Set<int> weekdays = {1, 2, 3, 4, 5};
  static const Set<int> everyDay = {1, 2, 3, 4, 5, 6, 7};

  /// ISO weekdays, 1 = Monday … 7 = Sunday (`DateTime.weekday`).
  final Set<int> days;
  final int startMin;
  final int endMin;

  bool get isOvernight => endMin < startMin;

  /// `"HH:mm"` → minutes after midnight; malformed → 0.
  static int parseHHmm(String? s) {
    final parts = (s ?? '').split(':');
    if (parts.length != 2) return 0;
    final h = (int.tryParse(parts[0]) ?? 0).clamp(0, 23);
    final m = (int.tryParse(parts[1]) ?? 0).clamp(0, 59);
    return h * 60 + m;
  }

  /// Minutes after midnight → `"HH:mm"` (24 h, like the web blocker's
  /// "Paused until").
  static String formatHHmm(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  Map<String, dynamic> toJson() => {
    'type': 'REPEATING',
    'repeatDays': days.toList()..sort(),
    'timeStart': formatHHmm(startMin),
    'timeEnd': formatHHmm(endMin),
  };

  @override
  List<Object?> get props => [days, startMin, endMin];
}

/// One user-authored blocking rule. Persisted as JSON under `StoreKeys.rules`
/// in the plan-doc vocabulary (`enabledState`, `activation`, `timeLimit`,
/// `openLimit`) so deferred features (snooze, date ranges, fixed-duration
/// locks) are additive; every field is read null- AND type-tolerantly, so a
/// document written by a newer build degrades a field instead of throwing.
class Rule extends Equatable {
  const Rule({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdAtMs,
    this.enabled = true,
    this.selection = const RuleSelection(),
    this.schedule,
    this.thresholdMs = 0,
    this.maxOpens = 0,
    this.strict = false,
    this.locked = false,
    this.lockScope = LockScope.selection,
  });

  /// Null when `kind` is unknown or `id` is missing — the repository drops
  /// such a document rather than turning it into a rule it cannot evaluate.
  /// Native skips a row without an id, so an id-less rule would list and
  /// toggle while enforcing nothing, and `remove('')` would take every one.
  static Rule? fromJson(Map<String, dynamic> m) {
    final kind = RuleKind.fromWire(_str(m['kind']));
    if (kind == null) return null;
    final id = _str(m['id']) ?? '';
    if (id.isEmpty) return null;
    final selection = _map(m['selection']);
    final activation = _map(m['activation']);
    final timeLimit = _map(m['timeLimit']);
    final openLimit = _map(m['openLimit']);
    return Rule(
      id: id,
      name: _str(m['name']) ?? '',
      kind: kind,
      createdAtMs: _int(m['createdAtMs']),
      enabled: _str(m['enabledState']) != 'DISABLED',
      selection: selection == null
          ? const RuleSelection()
          : RuleSelection.fromJson(selection),
      schedule:
          kind == RuleKind.schedule &&
              activation != null &&
              activation['type'] == 'REPEATING'
          ? RuleSchedule.fromJson(activation)
          : null,
      thresholdMs: _int(timeLimit?['thresholdMs']),
      maxOpens: _int(openLimit?['numberOfOpens']),
      strict: m['strict'] == true,
      locked: m['locked'] == true,
      lockScope: LockScope.fromWire(_str(m['lockScope'])),
    );
  }

  /// The single validity rule, enforced by BOTH the editor and `RulesCubit`'s
  /// `save` — the web blocker's shared-helper idiom (`DomainValidator.check`),
  /// so the two can never drift. Returns the user-facing reason, or null when
  /// the rule is savable.
  String? validate() {
    if (kind == RuleKind.schedule) {
      final s = schedule;
      if (s == null || s.days.isEmpty) return 'Pick at least one day.';
      if (s.startMin == s.endMin) {
        return 'Start and end cannot be the same time.';
      }
    }
    // `resolveSnapshot` emits no entry at all for a budget of zero, so such a
    // rule lists as "0 min a day" and blocks nothing. Unreachable from the
    // sliders; reachable from a restored document whose budget map is gone.
    if (kind == RuleKind.timeLimit && thresholdMs <= 0) {
      return 'Pick a daily budget.';
    }
    if (kind == RuleKind.openLimit && maxOpens <= 0) {
      return 'Pick how many opens a day.';
    }
    if (selection.isEmpty) {
      return 'Pick at least one app, category, site or reel feed.';
    }
    return null;
  }

  final String id;
  final String name;
  final RuleKind kind;
  final int createdAtMs;
  final bool enabled;
  final RuleSelection selection;

  /// The weekly window; `SCHEDULE` rules only.
  final RuleSchedule? schedule;

  /// Daily foreground budget; `TIME_LIMIT` rules only.
  final int thresholdMs;

  /// Launches allowed per day; `OPEN_LIMIT` rules only.
  final int maxOpens;

  /// EVO-030: a Pause (and an emergency pass) does NOT lift this rule. Off by
  /// default — the M3 decision that a Pause lifts rules stands; this is the
  /// per-rule opt-out for the ones you set because you don't trust future-you.
  /// App Blocker locks were always unconditional and are unaffected.
  final bool strict;

  /// M8: this rule has no off switch. Not greyed out — *absent*: the tile
  /// renders no toggle and no delete, and `lockGuard` refuses the mutation in
  /// the domain layer too, because a rule that can be disabled through a side
  /// door is not locked. The only relief is an override, which spends quota and
  /// names a reason.
  ///
  /// **Set once, at creation, and never cleared.** There is deliberately no
  /// in-app unlock: the commitment is the feature. The unwind of last resort is
  /// Settings → Reset app data (or turning the accessibility service off), and
  /// the settings copy says so.
  ///
  /// Implies [strict] on the wire (see `resolveSnapshot`) — a locked rule a
  /// two-minute Pause lifts would be theatre. Native therefore learns nothing
  /// new: `locked` never reaches the snapshot.
  final bool locked;

  /// How wide the lock reaches. Meaningless while [locked] is false.
  final LockScope lockScope;

  /// Whether a Pause lifts this rule — the single question native is asked.
  /// Locking implies it, so the two axes collapse to one wire field.
  bool get isStrict => strict || locked;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.wire,
    'enabledState': enabled ? 'ENABLED' : 'DISABLED',
    'createdAtMs': createdAtMs,
    'selection': selection.toJson(),
    'activation': schedule?.toJson() ?? const {'type': 'ALWAYS_ON'},
    if (kind == RuleKind.timeLimit)
      'timeLimit': {'thresholdMs': thresholdMs, 'lockPeriod': 'END_OF_DAY'},
    if (kind == RuleKind.openLimit) 'openLimit': {'numberOfOpens': maxOpens},
    if (strict) 'strict': true,
    // Sparse, like `strict`: an unlocked rule's document is byte-identical to
    // one written before M8.
    if (locked) 'locked': true,
    if (locked && lockScope != LockScope.selection) 'lockScope': lockScope.wire,
  };

  Rule copyWith({
    String? name,
    bool? enabled,
    RuleSelection? selection,
    RuleSchedule? schedule,
    int? thresholdMs,
    int? maxOpens,
    bool? strict,
    bool? locked,
    LockScope? lockScope,
  }) => Rule(
    id: id,
    name: name ?? this.name,
    kind: kind,
    createdAtMs: createdAtMs,
    enabled: enabled ?? this.enabled,
    selection: selection ?? this.selection,
    schedule: schedule ?? this.schedule,
    thresholdMs: thresholdMs ?? this.thresholdMs,
    maxOpens: maxOpens ?? this.maxOpens,
    strict: strict ?? this.strict,
    locked: locked ?? this.locked,
    lockScope: lockScope ?? this.lockScope,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    kind,
    createdAtMs,
    enabled,
    selection,
    schedule,
    thresholdMs,
    maxOpens,
    strict,
    locked,
    lockScope,
  ];
}

List<String> _strings(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

// Type-tolerant, not just null-tolerant: a wrong-typed field in one stored
// document must degrade that field, never throw out of the whole list. A cast
// here would take all 50 rules down with one bad value.
String? _str(Object? v) => v is String ? v : null;

int _int(Object? v) => v is num ? v.toInt() : 0;

List<Object?> _list(Object? v) => v is List ? v : const [];
