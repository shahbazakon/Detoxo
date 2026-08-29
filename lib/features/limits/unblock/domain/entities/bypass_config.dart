import 'package:equatable/equatable.dart';

/// The durations a temporary unblock can be taken for. The web blocker's
/// per-site pause sheet has offered exactly these since EVO-012 — one duration
/// vocabulary for the whole product, not two to learn.
const List<int> unblockDurationMinutes = [5, 15, 30, 60];

/// How long a quota period runs. A stable name string on the wire; `WEEK` means
/// a **rolling** seven days, not a calendar week.
enum BypassPeriod {
  day('DAY', Duration(days: 1)),
  week('WEEK', Duration(days: 7));

  const BypassPeriod(this.wire, this.length);

  final String wire;
  final Duration length;

  static BypassPeriod fromWire(String? v) => v == day.wire ? day : week;
}

/// The knobs behind the rationed escapes. Persisted alongside the ledger
/// entries in the same document so there is one thing to read.
///
/// Defaults are Detoxo product decisions: two overrides a week is enough that
/// the honest path is always open, and few enough that spending one is felt.
/// Never ship `overrideLimit: 0` — a lock nobody can ever lift is a lock people
/// escape by uninstalling.
class BypassConfig extends Equatable {
  const BypassConfig({
    this.overrideLimit = 2,
    this.overridePeriod = BypassPeriod.week,
    this.overrideMaxWindowMs = 60 * 60 * 1000,
    this.grantLimit = 0,
    this.grantPeriod = BypassPeriod.day,
  });

  factory BypassConfig.fromJson(Map<String, dynamic> m) => BypassConfig(
    overrideLimit: m['overrideLimit'] is num
        ? (m['overrideLimit']! as num).toInt().clamp(1, 20)
        : 2,
    overridePeriod: BypassPeriod.fromWire(
      m['overridePeriod'] is String ? m['overridePeriod']! as String : null,
    ),
    overrideMaxWindowMs: m['overrideMaxWindowMs'] is num
        ? (m['overrideMaxWindowMs']! as num).toInt().clamp(
            60 * 1000,
            4 * 60 * 60 * 1000,
          )
        : 60 * 60 * 1000,
    // Clamped from ZERO, unlike overrideLimit: 0 is the documented "unlimited"
    // sentinel here, and it is the default. A lock nobody can lift is a lock
    // people uninstall; an allowance nobody set is simply not a budget yet.
    grantLimit: m['grantLimit'] is num
        ? (m['grantLimit']! as num).toInt().clamp(0, 50)
        : 0,
    grantPeriod: BypassPeriod.fromWire(
      m['grantPeriod'] is String ? m['grantPeriod']! as String : 'DAY',
    ),
  );

  static const BypassConfig defaults = BypassConfig();

  /// Overrides allowed per [overridePeriod]. Clamped to at least 1 on read.
  final int overrideLimit;

  final BypassPeriod overridePeriod;

  /// The longest lift a single override can buy.
  final int overrideMaxWindowMs;

  /// Per-target unblocks allowed per [grantPeriod]; **0 means unlimited**, and
  /// is the default, so nothing changes for anyone who has not opted in
  /// (EVO-053).
  ///
  /// This exists because M8 shipped two escapes with opposite economics: the
  /// commitment side was rationed and the escape side was not, so a 60-minute
  /// allowance could be re-taken the instant it lapsed — from the very wall the
  /// block raised. "Everything else stays protected" was true per window, not
  /// per day.
  final int grantLimit;

  final BypassPeriod grantPeriod;

  int get periodMs => overridePeriod.length.inMilliseconds;

  int get grantPeriodMs => grantPeriod.length.inMilliseconds;

  /// Whether grants are budgeted at all.
  bool get grantsRationed => grantLimit > 0;

  BypassConfig copyWith({int? grantLimit, BypassPeriod? grantPeriod}) =>
      BypassConfig(
        overrideLimit: overrideLimit,
        overridePeriod: overridePeriod,
        overrideMaxWindowMs: overrideMaxWindowMs,
        grantLimit: grantLimit ?? this.grantLimit,
        grantPeriod: grantPeriod ?? this.grantPeriod,
      );

  Map<String, dynamic> toJson() => {
    'overrideLimit': overrideLimit,
    'overridePeriod': overridePeriod.wire,
    'overrideMaxWindowMs': overrideMaxWindowMs,
    'grantLimit': grantLimit,
    'grantPeriod': grantPeriod.wire,
  };

  @override
  List<Object?> get props => [
    overrideLimit,
    overridePeriod,
    overrideMaxWindowMs,
    grantLimit,
    grantPeriod,
  ];
}
