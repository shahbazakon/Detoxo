import 'package:detoxo/features/usage/usage.dart';
import 'package:equatable/equatable.dart';

/// One local day of honest, OS-sourced behaviour, rolled up from
/// `UsageStatsManager` rows by `computeDailyStats`.
///
/// Every duration here is the number the phone's own Digital Wellbeing shows —
/// including a visible-but-idle app. That is deliberately the same bar the OS
/// sets; a "smarter" figure the user cannot reconcile against Settings is worse
/// than an honest one.
class DailyStats extends Equatable {
  const DailyStats({
    required this.dayKey,
    this.screenTimeMs = 0,
    this.distractionMs = 0,
    this.distractionOpens = 0,
    this.pickupCount = 0,
    this.firstPickupMs,
    this.lastPickupMs,
    this.contextSwitches = 0,
    this.reelCount = 0,
    this.topApps = const [],
    this.computedAtMs = 0,
    this.complete = false,
  });

  /// Never throws. A missing field reads as zero and a **wrong-typed** one does
  /// too: this document is on disk, so a half-written frame, a hand-edit or an
  /// older schema must degrade to a dull day rather than take the screen down.
  /// [dayKey] comes from the map key, not the document.
  factory DailyStats.fromJson(String dayKey, Map<String, dynamic> json) =>
      DailyStats(
        dayKey: dayKey,
        screenTimeMs: _int(json['screenTimeMs']),
        distractionMs: _int(json['distractionMs']),
        distractionOpens: _int(json['distractionOpens']),
        pickupCount: _int(json['pickupCount']),
        firstPickupMs: _intOrNull(json['firstPickupMs']),
        lastPickupMs: _intOrNull(json['lastPickupMs']),
        contextSwitches: _int(json['contextSwitches']),
        reelCount: _int(json['reelCount']),
        // Re-sorted on read: every consumer assumes "first is busiest", and a
        // hand-edited or older document need not honour that.
        topApps: [
          for (final e in _list(json['topApps']))
            if (e is Map && e['package'] is String && e['package'] != '')
              AppUsage(
                package: e['package'] as String,
                foregroundMillis: _int(e['ms']),
              ),
        ]..sort((a, b) => b.foregroundMillis.compareTo(a.foregroundMillis)),
        computedAtMs: _int(json['computedAtMs']),
        // `== true` rather than a cast: a stored 1 or "true" must not throw.
        complete: json['complete'] == true,
      );

  /// The day key this record is filed under — `dd-MM-yyyy`, always from
  /// `daySignature`. Never the web blocker's `yyyy-MM-dd`.
  final String dayKey;

  final int screenTimeMs;

  /// Foreground time on apps the catalog calls `distracting`.
  final int distractionMs;

  /// Foreground *transitions* into a distracting app — an app resuming its own
  /// next activity is not a new open (the native `UsageQuery.countOpens` rule).
  final int distractionOpens;

  final int pickupCount;

  /// Epoch ms of the first / last screen-on of the day; null on a day with no
  /// pickup events (which is not the same as a day with zero pickups recorded
  /// — a caller must render "—", never a midnight timestamp).
  final int? firstPickupMs;
  final int? lastPickupMs;

  /// How often attention jumped from one app to another.
  final int contextSwitches;

  /// The reel counter's figure for the same day, so it can be read as a share
  /// of real screen time rather than in isolation.
  final int reelCount;

  /// Up to 10 apps by foreground time, descending.
  final List<AppUsage> topApps;

  final int computedAtMs;

  /// False while this is still today. A partial day charted as a finished one
  /// makes every "today vs average" comparison read low until bedtime.
  final bool complete;

  Duration get screenTime => Duration(milliseconds: screenTimeMs);
  Duration get distraction => Duration(milliseconds: distractionMs);

  /// Distraction as a fraction of screen time, `0` when nothing was recorded.
  double get distractionShare =>
      screenTimeMs <= 0 ? 0 : distractionMs / screenTimeMs;

  DateTime? get firstPickup => firstPickupMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(firstPickupMs!);
  DateTime? get lastPickup => lastPickupMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastPickupMs!);

  /// Nothing was recorded — the screen shows the "quiet day" copy rather than a
  /// grid of zeros. Distinct from *unknown*, which is `UsageQueryResult`'s job.
  bool get isEmpty => screenTimeMs == 0 && pickupCount == 0 && reelCount == 0;

  /// [dayKey] is the map key and is not written into the document.
  Map<String, dynamic> toJson() => {
    'screenTimeMs': screenTimeMs,
    'distractionMs': distractionMs,
    'distractionOpens': distractionOpens,
    'pickupCount': pickupCount,
    if (firstPickupMs != null) 'firstPickupMs': firstPickupMs,
    if (lastPickupMs != null) 'lastPickupMs': lastPickupMs,
    'contextSwitches': contextSwitches,
    'reelCount': reelCount,
    'topApps': [
      for (final a in topApps) {'package': a.package, 'ms': a.foregroundMillis},
    ],
    'computedAtMs': computedAtMs,
    'complete': complete,
  };

  /// Zero for anything that is not a number — including a numeric string, a
  /// map, or a value a future schema change renames out from under this reader
  /// — and zero for a negative one: no duration or count here can be below it.
  static int _int(Object? v) {
    final n = _intOrNull(v) ?? 0;
    return n < 0 ? 0 : n;
  }

  static int? _intOrNull(Object? v) => switch (v) {
    final num n when n.isFinite => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };

  static List<dynamic> _list(Object? v) => v is List ? v : const [];

  @override
  List<Object?> get props => [
    dayKey,
    screenTimeMs,
    distractionMs,
    distractionOpens,
    pickupCount,
    firstPickupMs,
    lastPickupMs,
    contextSwitches,
    reelCount,
    topApps,
    computedAtMs,
    complete,
  ];
}
