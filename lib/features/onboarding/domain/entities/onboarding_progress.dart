import 'package:equatable/equatable.dart';

/// Where the first run has got to. The wire strings are a storage contract —
/// a rename is a migration. [completed] is terminal and never rendered.
enum OnboardingStepId {
  welcome('WELCOME'),
  survey('SURVEY'),
  projection('PROJECTION'),
  selection('SELECTION'),
  commitment('COMMITMENT'),
  permissions('PERMISSIONS'),
  completed('COMPLETED');

  const OnboardingStepId(this.wire);

  final String wire;

  /// Unknown token (a document from a newer build) degrades to [welcome]
  /// rather than throwing — the user replays a step instead of hitting a
  /// crash loop they cannot escape.
  static OnboardingStepId fromWire(String? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return OnboardingStepId.welcome;
  }

  /// The steps the walker renders, in order. [completed] is excluded: it is a
  /// terminal marker, not a screen, so the progress bar counts real steps.
  static const List<OnboardingStepId> visible = [
    welcome,
    survey,
    projection,
    selection,
    commitment,
    permissions,
  ];
}

/// Self-reported daily short-form time. [hoursPerDay] is the projection's only
/// input, so a band is a number with a label rather than a bare enum.
enum ScreenTimeBand {
  lessThan1h('LESS_THAN_1H', 0.5, 'Under 1 hour'),
  between1And2h('BETWEEN_1_AND_2H', 1.5, '1–2 hours'),
  between2And3h('BETWEEN_2_AND_3H', 2.5, '2–3 hours'),
  between3And4h('BETWEEN_3_AND_4H', 3.5, '3–4 hours'),
  between4And5h('BETWEEN_4_AND_5H', 4.5, '4–5 hours'),
  between5And7h('BETWEEN_5_AND_7H', 6, '5–7 hours'),
  over7h('OVER_7H', 8, 'More than 7 hours'),
  dontKnow('DONT_KNOW', 3, 'I honestly don’t know');

  const ScreenTimeBand(this.wire, this.hoursPerDay, this.label);

  final String wire;

  /// Midpoint of the band; the honest answer for [dontKnow] is the global
  /// average, not zero — a zero projection would reward not answering.
  final double hoursPerDay;
  final String label;

  static ScreenTimeBand? fromWire(String? v) {
    for (final b in values) {
      if (b.wire == v) return b;
    }
    return null;
  }
}

/// Why the user is here. Chooses the starter rule — see `starter_rule.dart`.
enum MattersMost {
  focus('FOCUS', 'Focus and getting things done'),
  sleep('SLEEP', 'Sleeping properly'),
  present('PRESENT', 'Being present with people'),
  mental('MENTAL', 'How scrolling makes me feel'),
  other('OTHER', 'Something else');

  const MattersMost(this.wire, this.label);

  final String wire;
  final String label;

  static MattersMost? fromWire(String? v) {
    for (final m in values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

/// The persisted first-run record. Hand-rolled JSON (the `Rule` / `AppSettings`
/// idiom, not freezed): every field is read null- AND type-tolerantly, so a
/// document written by a newer build degrades a field instead of throwing.
class OnboardingProgress extends Equatable {
  const OnboardingProgress({
    this.step = OnboardingStepId.welcome,
    this.name,
    this.band,
    this.mattersMost,
    this.platforms = const {},
    this.dailyLimitMinutes = defaultDailyLimitMinutes,
    this.startedAtMs = 0,
  });

  factory OnboardingProgress.fromJson(Map<String, dynamic> m) =>
      OnboardingProgress(
        step: OnboardingStepId.fromWire(_str(m['step'])),
        name: _str(m['name']),
        band: ScreenTimeBand.fromWire(_str(m['screenTimeBand'])),
        mattersMost: MattersMost.fromWire(_str(m['mattersMost'])),
        platforms: {
          for (final p in _list(_map(m['selection'])?['platforms']))
            if (p is String && p.isNotEmpty) p,
        },
        // Clamped, not trusted. The dial is the only bound in the UI, so a
        // hand-edited or restored record could otherwise hand `setLimit` a 0 —
        // which `DailyLimit.isExceeded` reads as "no limit at all", silently
        // switching off the ceiling while the screen still shows one.
        dailyLimitMinutes: _int(
          m['dailyLimitMinutes'],
          fallback: defaultDailyLimitMinutes,
        ).clamp(minDailyLimitMinutes, maxDailyLimitMinutes),
        startedAtMs: _int(m['startedAtMs']),
      );

  /// Seeds the commitment step's dial. Matches the value the old five-page
  /// onboarding wrote, so an upgrading user's default does not shift.
  static const int defaultDailyLimitMinutes = 90;

  /// The dial's own range (`ScreenTimeDial`: 15 min – 5 h). Restated here
  /// because a persisted record has to be bounded in the domain, not by the
  /// widget that happened to produce it.
  static const int minDailyLimitMinutes = 15;
  static const int maxDailyLimitMinutes = 5 * 60;

  final OnboardingStepId step;
  final String? name;
  final ScreenTimeBand? band;
  final MattersMost? mattersMost;

  /// `platformId`s picked on the selection step — the starter rule's targets.
  final Set<String> platforms;
  final int dailyLimitMinutes;
  final int startedAtMs;

  /// The projection step's headline: hours lost per year at this rate,
  /// expressed in whole days. Null until the band is answered.
  int? get daysPerYear =>
      band == null ? null : (band!.hoursPerDay * 365 / 24).round();

  Map<String, dynamic> toJson() => {
    'step': step.wire,
    'name': name,
    'screenTimeBand': band?.wire,
    'mattersMost': mattersMost?.wire,
    'selection': {'platforms': platforms.toList()..sort()},
    'dailyLimitMinutes': dailyLimitMinutes,
    'startedAtMs': startedAtMs,
  };

  /// [clearName] follows the `RulesState.copyWith(clearError:)` idiom: a null
  /// [name] means "unchanged", so erasing the text field needs its own flag or
  /// the commitment screen keeps greeting the user by a name they deleted.
  OnboardingProgress copyWith({
    OnboardingStepId? step,
    String? name,
    bool clearName = false,
    ScreenTimeBand? band,
    MattersMost? mattersMost,
    Set<String>? platforms,
    int? dailyLimitMinutes,
    int? startedAtMs,
  }) => OnboardingProgress(
    step: step ?? this.step,
    name: clearName ? null : (name ?? this.name),
    band: band ?? this.band,
    mattersMost: mattersMost ?? this.mattersMost,
    platforms: platforms ?? this.platforms,
    dailyLimitMinutes: dailyLimitMinutes ?? this.dailyLimitMinutes,
    startedAtMs: startedAtMs ?? this.startedAtMs,
  );

  @override
  List<Object?> get props => [
    step,
    name,
    band,
    mattersMost,
    platforms,
    dailyLimitMinutes,
    startedAtMs,
  ];
}

String? _str(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  return s.isEmpty ? null : s;
}

List<Object?> _list(Object? v) => v is List ? v : const [];

Map<String, dynamic>? _map(Object? v) => v is Map<String, dynamic> ? v : null;

int _int(Object? v, {int fallback = 0}) => v is num ? v.toInt() : fallback;
