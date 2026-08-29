import 'package:detoxo/features/blocking/plans/domain/entities/sessions.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// The user's blocking configuration. This is the single object Dart persists
/// locally and pushes to the native engine; the service reads from it.
///
/// Pause is modelled as a live [PauseSession]: an allowed window after which
/// blocking resumes as Block All. `activePlan` holds the *enforced* plan
/// (Block All / Conscious / One Reel); while a pause is live we *derive* what we
/// push to native — see [effectiveNativePlan] / [nativePauseUntil] — so the
/// verified phase math drives enforcement over the existing channel.
///
/// Conscious (the `curious` plan) is enforced natively as an earn-as-you-abstain
/// token bucket; Dart holds no live session for it — the running bank lives in
/// the engine so it survives the UI being killed.
class AppSettings extends Equatable {
  const AppSettings({
    this.activePlan = BlockingPlan.blockAll,
    this.defaultBlockMode = BlockingMode.pressBack,
    this.enabledPlatformIds = const {},
    this.vibrationEnabled = true,
    this.masterEnabled = true,
    this.pauseSession,
    this.baseMode = BlockingPlan.blockAll,
    this.reelAllowance = 1,
    this.onboarded = false,
    this.hasSeenFeatureShowcase = false,
    this.themeMode = AppThemeMode.dark,
    this.darkBackground = AppBackground.dark1,
    this.lightBackground = AppBackground.aurora,
    this.blockAdultWebsites = false,
    this.blockWebsitesForBlockedApps = false,
    this.showFeedbackButton = false,
    this.suppressNotifications = false,
    this.nudgeEnabled = false,
    this.nudgeThresholdMinutes = 5,
    this.nudgeDailyCap = 4,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    // Legacy migration: the old model stored `paused` as the active plan while a
    // pause ran. The new model keeps activePlan = Block All and tracks the live
    // pause purely via [pauseSession], so collapse any persisted `paused` to
    // Block All — otherwise an upgrade killed mid-pause would surface a phantom
    // "Paused" plan forever (no live window to clear it).
    final plan = BlockingPlan.fromWire(json['activePlan'] as String?);
    // The sticky base mode is only ever Block All or Conscious; anything else
    // persisted (an override plan, legacy `paused`) collapses to Block All.
    final base = BlockingPlan.fromWire(json['baseMode'] as String?);
    return AppSettings(
      activePlan: plan == BlockingPlan.paused ? BlockingPlan.blockAll : plan,
      baseMode: base == BlockingPlan.curious
          ? BlockingPlan.curious
          : BlockingPlan.blockAll,
      defaultBlockMode: BlockingMode.fromWire(
        json['defaultBlockMode'] as String?,
      ),
      enabledPlatformIds:
          ((json['enabledPlatformIds'] as List?)?.cast<String>() ?? const [])
              .toSet(),
      vibrationEnabled: json['vibrationEnabled'] as bool? ?? true,
      masterEnabled: json['masterEnabled'] as bool? ?? true,
      pauseSession: json['pauseSession'] == null
          ? null
          : PauseSession.fromJson(json['pauseSession'] as Map<String, dynamic>),
      reelAllowance: (json['reelAllowance'] as num?)?.toInt() ?? 1,
      onboarded: json['onboarded'] as bool? ?? false,
      hasSeenFeatureShowcase: json['hasSeenFeatureShowcase'] as bool? ?? false,
      themeMode: AppThemeMode.fromWire(json['themeMode'] as String?),
      darkBackground: AppBackground.fromWire(
        json['darkBackground'] as String?,
        fallback: AppBackground.dark1,
      ),
      lightBackground: AppBackground.fromWire(
        json['lightBackground'] as String?,
      ),
      blockAdultWebsites: json['blockAdultWebsites'] as bool? ?? false,
      blockWebsitesForBlockedApps:
          json['blockWebsitesForBlockedApps'] as bool? ?? false,
      showFeedbackButton: json['showFeedbackButton'] as bool? ?? false,
      suppressNotifications: json['suppressNotifications'] as bool? ?? false,
      // Clamped to the same range the native engine coerces to, so a
      // corrupt or hand-edited blob can't render "up to -5 per app a day"
      // in Settings while the engine quietly enforces 1.
      nudgeEnabled: json['nudgeEnabled'] as bool? ?? false,
      nudgeThresholdMinutes:
          ((json['nudgeThresholdMinutes'] as num?)?.toInt() ?? 5).clamp(1, 60),
      nudgeDailyCap: ((json['nudgeDailyCap'] as num?)?.toInt() ?? 4).clamp(
        1,
        50,
      ),
    );
  }

  final BlockingPlan activePlan;
  final BlockingMode defaultBlockMode;
  final Set<String> enabledPlatformIds;
  final bool vibrationEnabled;
  final bool masterEnabled;

  /// Live pause contract (an allowed window). Null = none.
  final PauseSession? pauseSession;

  /// The sticky base plan an override mode returns to. Only ever [BlockingPlan.blockAll]
  /// (default) or [BlockingPlan.curious]: choosing a base mode sets it, and the
  /// temporary override modes (One Reel / Unblock / Pause) auto-revert here when
  /// their unit (count / time) completes.
  final BlockingPlan baseMode;

  /// How many reels the One Reel / Unblock plan allows before it re-blocks
  /// (1..20). `oneReel` with `reelAllowance == 1` is the "One Reel" mode; a
  /// value ≥ 2 is the "Unblock N" mode. The native engine owns the running
  /// consumed-count (re-armed on each mode tap); this is only the target.
  final int reelAllowance;
  final bool onboarded;

  /// Whether the one-time feature showcase / walkthrough has been seen. Drives
  /// the auto-start on first Dashboard visit; reset to `false` to replay the tour.
  final bool hasSeenFeatureShowcase;

  /// Appearance preference (drives the Flutter `ThemeMode` in the UI layer).
  final AppThemeMode themeMode;

  /// Animated background choices — one per theme, so switching theme keeps each
  /// mode's own pick (drives the design-system background in the UI layer). Dark
  /// mode uses one of the `dark*` options; light mode uses `aurora`/`light*`.
  final AppBackground darkBackground;
  final AppBackground lightBackground;

  /// Website-blocker toggles, pushed to native via [toJson]/pushSettings. The
  /// variable-length blocklist itself ships separately (pushWebBlocklist); these
  /// are the two scalar switches the engine reads each tick.
  final bool blockAdultWebsites;
  final bool blockWebsitesForBlockedApps;

  /// Whether the global feedback button is shown in screen app bars. UI-only
  /// (the native engine ignores it); persisted through the single settings path.
  final bool showFeedbackButton;

  /// Whether notifications from currently-blocked apps are cancelled. Opt-in
  /// and off by default: it needs Android's notification-access grant, which is
  /// broader than everything else Detoxo asks for. Native derives WHICH apps
  /// per notification from the live engine state — only this switch is pushed.
  final bool suppressNotifications;

  /// Soft nudge: after this many minutes in one distracting app, a dismissible
  /// card says so, and it returns at every further multiple. Advisory only —
  /// nothing is blocked and nothing is pressed.
  ///
  /// Note the shape of it, because two plausible readings differ: this is
  /// elapsed time inside ONE visit to ONE app, not cumulative use across the
  /// day. Two four-minute visits never nudge. "Tell me after 30 minutes today"
  /// is the daily limit, which already exists — point the user there instead.
  final bool nudgeEnabled;
  final int nudgeThresholdMinutes;

  /// Nudges per app per day before the machine goes quiet. A card every five
  /// minutes forever is ignorable by the third one.
  final int nudgeDailyCap;

  DateTime _now(DateTime? now) => now ?? DateTime.now();

  // ── Derived session state ─────────────────────────────────────────────────

  SessionPhase pausePhase([DateTime? now]) =>
      pauseSession?.phaseAt(_now(now)) ?? SessionPhase.idle;

  /// A pause contract is live (inside the allowed window) — drives the pause
  /// screen / dashboard banner.
  bool isPauseContractLive([DateTime? now]) {
    final ps = pauseSession;
    return ps != null && _now(now).isBefore(ps.pauseEnd);
  }

  /// Content is currently allowed because we're inside the pause window.
  bool isPaused([DateTime? now]) => isPauseContractLive(now);

  /// The plan the native detector enforces when it is NOT suspended. The pause
  /// window is carved out via [nativePauseUntil]; this value bites once the
  /// pause lapses (always Block All — pauses resume into Block All).
  BlockingPlan effectiveNativePlan([DateTime? now]) {
    final ps = pauseSession;
    if (ps != null && _now(now).isBefore(ps.pauseEnd)) return ps.planToResume;
    return activePlan;
  }

  /// Epoch the native side should treat as "all blocking suspended until" — the
  /// end of the pause window. Null when no pause is live.
  DateTime? nativePauseUntil([DateTime? now]) {
    final ps = pauseSession;
    if (ps != null && _now(now).isBefore(ps.pauseEnd)) return ps.pauseEnd;
    return null;
  }

  AppSettings copyWith({
    BlockingPlan? activePlan,
    BlockingMode? defaultBlockMode,
    Set<String>? enabledPlatformIds,
    bool? vibrationEnabled,
    bool? masterEnabled,
    PauseSession? pauseSession,
    bool clearPauseSession = false,
    BlockingPlan? baseMode,
    int? reelAllowance,
    bool? onboarded,
    bool? hasSeenFeatureShowcase,
    AppThemeMode? themeMode,
    AppBackground? darkBackground,
    AppBackground? lightBackground,
    bool? blockAdultWebsites,
    bool? blockWebsitesForBlockedApps,
    bool? showFeedbackButton,
    bool? suppressNotifications,
    bool? nudgeEnabled,
    int? nudgeThresholdMinutes,
    int? nudgeDailyCap,
  }) {
    return AppSettings(
      activePlan: activePlan ?? this.activePlan,
      defaultBlockMode: defaultBlockMode ?? this.defaultBlockMode,
      enabledPlatformIds: enabledPlatformIds ?? this.enabledPlatformIds,
      vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
      masterEnabled: masterEnabled ?? this.masterEnabled,
      pauseSession: clearPauseSession
          ? null
          : (pauseSession ?? this.pauseSession),
      baseMode: baseMode ?? this.baseMode,
      reelAllowance: reelAllowance ?? this.reelAllowance,
      onboarded: onboarded ?? this.onboarded,
      hasSeenFeatureShowcase:
          hasSeenFeatureShowcase ?? this.hasSeenFeatureShowcase,
      themeMode: themeMode ?? this.themeMode,
      darkBackground: darkBackground ?? this.darkBackground,
      lightBackground: lightBackground ?? this.lightBackground,
      blockAdultWebsites: blockAdultWebsites ?? this.blockAdultWebsites,
      blockWebsitesForBlockedApps:
          blockWebsitesForBlockedApps ?? this.blockWebsitesForBlockedApps,
      showFeedbackButton: showFeedbackButton ?? this.showFeedbackButton,
      suppressNotifications:
          suppressNotifications ?? this.suppressNotifications,
      nudgeEnabled: nudgeEnabled ?? this.nudgeEnabled,
      nudgeThresholdMinutes:
          nudgeThresholdMinutes ?? this.nudgeThresholdMinutes,
      nudgeDailyCap: nudgeDailyCap ?? this.nudgeDailyCap,
    );
  }

  Map<String, dynamic> toJson() => {
    'activePlan': activePlan.wire,
    'defaultBlockMode': defaultBlockMode.wire,
    'enabledPlatformIds': enabledPlatformIds.toList(),
    'vibrationEnabled': vibrationEnabled,
    'masterEnabled': masterEnabled,
    'pauseSession': pauseSession?.toJson(),
    'baseMode': baseMode.wire,
    'reelAllowance': reelAllowance,
    'onboarded': onboarded,
    'hasSeenFeatureShowcase': hasSeenFeatureShowcase,
    'themeMode': themeMode.wire,
    'darkBackground': darkBackground.wire,
    'lightBackground': lightBackground.wire,
    'blockAdultWebsites': blockAdultWebsites,
    'blockWebsitesForBlockedApps': blockWebsitesForBlockedApps,
    'showFeedbackButton': showFeedbackButton,
    'suppressNotifications': suppressNotifications,
    'nudgeEnabled': nudgeEnabled,
    'nudgeThresholdMinutes': nudgeThresholdMinutes,
    'nudgeDailyCap': nudgeDailyCap,
  };

  @override
  List<Object?> get props => [
    activePlan,
    defaultBlockMode,
    enabledPlatformIds,
    vibrationEnabled,
    masterEnabled,
    pauseSession,
    baseMode,
    reelAllowance,
    onboarded,
    hasSeenFeatureShowcase,
    themeMode,
    darkBackground,
    lightBackground,
    blockAdultWebsites,
    blockWebsitesForBlockedApps,
    showFeedbackButton,
    suppressNotifications,
    nudgeEnabled,
    nudgeThresholdMinutes,
    nudgeDailyCap,
  ];
}
