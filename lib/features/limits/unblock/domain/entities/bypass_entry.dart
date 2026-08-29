import 'package:equatable/equatable.dart';

/// Hard cap on ledger rows, pruned on write. At 2 overrides a week that is
/// roughly six months of history.
const int maxBypassEntries = 50;

/// Which rationed escape a ledger row records. ONE store with a discriminator,
/// not two stores: the emergency pass (M2.2) and the override (M8) are the same
/// rationed thing at different scopes, so there is one number to understand.
///
/// [emergency] was declared from day one so M2.2 adds a preset rather than
/// renaming a persisted key, which is a one-way door — and [grant] (EVO-053)
/// is the proof that paid off: a third preset, no migration.
enum BypassKind {
  /// M2.2, not built yet: break-glass, everything, 1 per 7 days, fixed hour.
  emergency('EMERGENCY'),

  /// M8: one locked rule, 2 per rolling 7 days, reason required, window chosen.
  override('OVERRIDE'),

  /// EVO-053: one target freed for a while. Unlimited by default, so this
  /// counts nothing until the user sets a daily allowance — but it is recorded
  /// either way, because a budget you switch on tomorrow needs today's history
  /// to mean anything.
  grant('GRANT');

  const BypassKind(this.wire);

  final String wire;

  /// Null for an unknown token so the row is dropped instead of being counted
  /// against the wrong quota.
  static BypassKind? fromWire(String? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// Why the user is spending an override. C2's six, kept verbatim on the wire —
/// making you name the reason is the point of the picker, so the list is not
/// "improved" into something vaguer.
enum OverrideReason {
  feelingSick('FEELING_SICK', 'Feeling unwell'),
  medicalAppointment('MEDICAL_APPOINTMENT', 'Medical appointment'),
  family('FAMILY', 'Family'),
  scheduleChange('SCHEDULE_CHANGE', 'My schedule changed'),
  wrongSchedule('WRONG_SCHEDULE', 'I set this rule up wrong'),
  other('OTHER', 'Something else');

  const OverrideReason(this.wire, this.label);

  final String wire;

  /// User-facing; never the wire token.
  final String label;

  static OverrideReason? fromWire(String? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

/// One spent escape. Only the timestamps and the choice persist — `remaining`,
/// `resetsAt` and `canOverride` are computed from this list every time, so
/// there is no cached count that can drift out of sync with the rows that
/// produced it.
class BypassEntry extends Equatable {
  const BypassEntry({
    required this.kind,
    required this.atMs,
    this.untilMs = 0,
    this.ruleId,
    this.reason,
  });

  /// Null for an unknown kind — dropped rather than miscounted.
  static BypassEntry? fromJson(Map<String, dynamic> m) {
    final kind = BypassKind.fromWire(_str(m['kind']));
    if (kind == null) return null;
    return BypassEntry(
      kind: kind,
      atMs: _int(m['atMs']),
      untilMs: _int(m['untilMs']),
      ruleId: _str(m['ruleId']),
      reason: OverrideReason.fromWire(_str(m['reason'])),
    );
  }

  final BypassKind kind;

  /// When it was spent — the only thing the quota counts.
  final int atMs;

  /// When the lift it bought ends. A chosen value, not a derived one: the
  /// snapshot resolver reads it to punch the window out of the rule.
  final int untilMs;

  /// The locked rule this override lifts; null for an emergency pass.
  final String? ruleId;

  /// Required for an override, optional for an emergency pass.
  final OverrideReason? reason;

  bool isLiftActiveAt(int nowMs) => atMs <= nowMs && nowMs < untilMs;

  Map<String, dynamic> toJson() => {
    'kind': kind.wire,
    'atMs': atMs,
    'untilMs': untilMs,
    'ruleId': ruleId,
    'reason': reason?.wire,
  };

  @override
  List<Object?> get props => [kind, atMs, untilMs, ruleId, reason];
}

String? _str(Object? v) => v is String ? v : null;

int _int(Object? v) => v is num ? v.toInt() : 0;
