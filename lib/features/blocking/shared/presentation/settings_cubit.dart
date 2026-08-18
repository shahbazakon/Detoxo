import 'dart:async';

import 'package:detoxo/features/blocking/plans/domain/entities/reel_session_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/sessions.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Owns the user's [AppSettings] and drives the mode state machine.
///
/// Modes split into two kinds. **Base modes** (Block All — default, and Conscious
/// = the `curious` plan) are sticky: picking one records it as the `baseMode`.
/// **Override modes** (One Reel / Unblock / Pause) are
/// temporary — when their unit (reel count / time) completes the app auto-reverts
/// to the base mode. Pause reverts via its 1 Hz ticker; One Reel / Unblock revert
/// when the native engine signals the allowance is spent (see [_onReelSession]).
///
/// Every mutation persists locally and pushes the (derived) state to the native
/// engine.
class SettingsCubit extends Cubit<AppSettings> {
  SettingsCubit(this._settings, this._engine) : super(const AppSettings()) {
    // Auto-revert One Reel / Unblock to the base mode once the native allowance
    // is spent (native owns the count; this only flips the plan back).
    _reelSub = _engine.reelSessionStream().listen(_onReelSession);
  }

  final SettingsRepository _settings;
  final EngineRepository _engine;

  Timer? _ticker;
  StreamSubscription<ReelSessionState>? _reelSub;

  Future<void> bootstrap() async {
    final loaded = await _settings.load();
    emit(loaded);
    await _engine.pushSettings(loaded);
    _syncTicker(loaded);
  }

  /// Load-modify-write: the transform is applied to a FRESH load, not to the
  /// in-memory state. Other writers exist (the Web Blocker's two protection
  /// toggles write the repository directly), and building from `state.copyWith`
  /// would silently revert their fields on the next unrelated commit here.
  Future<void> _commit(AppSettings Function(AppSettings) update) async {
    final next = update(await _settings.load());
    emit(next);
    await _settings.save(next);
    await _engine.pushSettings(next);
    _syncTicker(next);
  }

  /// Switch the active plan. Clears any live pause (the user is choosing a fresh
  /// plan). Choosing a base mode (Block All / Conscious) also records it as the
  /// sticky `baseMode` that override modes revert to.
  Future<void> setPlan(BlockingPlan plan) {
    final isBase =
        plan == BlockingPlan.blockAll || plan == BlockingPlan.curious;
    return _commit(
      (s) => s.copyWith(
        activePlan: plan,
        baseMode: isBase ? plan : null,
        clearPauseSession: true,
      ),
    );
  }

  Future<void> setDefaultBlockMode(BlockingMode mode) =>
      _commit((s) => s.copyWith(defaultBlockMode: mode));

  Future<void> setMasterEnabled({required bool enabled}) =>
      _commit((s) => s.copyWith(masterEnabled: enabled));

  Future<void> setVibration({required bool enabled}) =>
      _commit((s) => s.copyWith(vibrationEnabled: enabled));

  /// Show/hide the global feedback button in screen app bars. UI-only (like
  /// [setThemeMode]); persisted through the single [_commit] path.
  Future<void> setShowFeedbackButton({required bool enabled}) =>
      _commit((s) => s.copyWith(showFeedbackButton: enabled));

  /// Appearance preference. UI-only; pushing to native is harmless (the engine
  /// ignores the field) and keeps a single persistence path.
  Future<void> setThemeMode(AppThemeMode mode) =>
      _commit((s) => s.copyWith(themeMode: mode));

  /// Animated background choice for one theme. UI-only (like [setThemeMode]);
  /// the native engine ignores it and persistence flows through [_commit]. Pass
  /// [dark] for the mode being edited so each theme keeps its own pick.
  Future<void> setBackground(AppBackground background, {required bool dark}) =>
      _commit(
        (s) => dark
            ? s.copyWith(darkBackground: background)
            : s.copyWith(lightBackground: background),
      );

  Future<void> setOnboarded({required bool value}) =>
      _commit((s) => s.copyWith(onboarded: value));

  /// Marks the one-time feature showcase as seen (true) or queues a replay
  /// (false). The Dashboard's coordinator starts the tour on the true→false edge
  /// and writes `true` back once the tour finishes or is dismissed.
  Future<void> setShowcaseSeen({required bool value}) =>
      _commit((s) => s.copyWith(hasSeenFeatureShowcase: value));

  Future<void> togglePlatform(String platformId, {required bool enabled}) {
    final next = Set<String>.from(state.enabledPlatformIds);
    if (enabled) {
      next.add(platformId);
    } else {
      next.remove(platformId);
    }
    return _commit((s) => s.copyWith(enabledPlatformIds: next));
  }

  Future<void> setEnabledPlatforms(Set<String> ids) =>
      _commit((s) => s.copyWith(enabledPlatformIds: ids));

  // ── Pause ──────────────────────────────────────────────────────────────────

  /// Start a pause: every app is allowed for the [pause] window, after which
  /// blocking resumes as the sticky base mode (Block All or Conscious). The plan
  /// is set to the base up front so when the window lapses (even while the app is
  /// dead) the state is already correct; the live pause is tracked purely by the
  /// pause session.
  Future<void> startPause({required Duration pause}) {
    final session = PauseSession(
      startedAt: DateTime.now(),
      pauseDuration: pause,
      cooldownDuration:
          Duration.zero, // no wind-down: straight to the base mode
      planToResume: state.baseMode,
    );
    return _commit(
      (s) => s.copyWith(activePlan: s.baseMode, pauseSession: session),
    );
  }

  /// "Resume blocking now" — end the pause immediately and return to the base mode.
  Future<void> resumeNow() {
    if (state.pauseSession == null) return Future.value();
    return _commit(
      (s) => s.copyWith(activePlan: s.baseMode, clearPauseSession: true),
    );
  }

  // ── Conscious ───────────────────────────────────────────────────────────────

  /// Turn on Conscious (earn-as-you-abstain) and start a fresh, empty bank. The
  /// explicit reset means a later auto-revert *into* Conscious keeps the earned
  /// bank — only a genuine user entry starts from zero.
  Future<void> enterConscious() async {
    await setPlan(BlockingPlan.curious);
    await _engine.resetConsciousBank();
  }

  /// Exit Conscious and fall back to Block All.
  Future<void> stopConscious() => setPlan(BlockingPlan.blockAll);

  // ── One Reel / Unblock ──────────────────────────────────────────────────────

  /// Arm the One Reel (count 1) / Unblock (count 2..20) plan: allow [count]
  /// reels, then re-block. Re-arms a fresh allowance on every call — the native
  /// consumed-count is reset via the imperative `armReelSession` command, so an
  /// unrelated settings push can't re-arm mid-session.
  Future<void> setOneReel({required int count}) async {
    final n = count.clamp(1, 20);
    await _commit(
      (s) => s.copyWith(
        activePlan: BlockingPlan.oneReel,
        reelAllowance: n,
        clearPauseSession: true,
      ),
    );
    await _engine.armReelSession(n);
  }

  // ── Pause ticker ────────────────────────────────────────────────────────────

  void _syncTicker(AppSettings s) {
    final live = s.isPauseContractLive();
    if (live && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    } else if (!live && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  Future<void> _onTick() async {
    final s = state;
    // Pause window finished → settle the state back to the base mode and drop
    // the session. (activePlan is already the base; this just clears the banner.)
    if (s.pauseSession != null && !s.isPauseContractLive()) {
      await _commit(
        (cur) =>
            cur.copyWith(activePlan: cur.baseMode, clearPauseSession: true),
      );
    }
  }

  // ── One Reel / Unblock auto-revert ──────────────────────────────────────────

  /// Native signals the reel allowance is spent → return to the base mode. The
  /// `activePlan == oneReel` guard makes it idempotent: a second `blocked` event
  /// after the flip is ignored, and arming (which emits `blocked == false`) never
  /// trips it.
  void _onReelSession(ReelSessionState rs) {
    if (state.activePlan == BlockingPlan.oneReel && rs.active && rs.blocked) {
      unawaited(
        _commit(
          (s) => s.copyWith(activePlan: s.baseMode, clearPauseSession: true),
        ),
      );
    }
  }

  @override
  Future<void> close() {
    _ticker?.cancel();
    _reelSub?.cancel();
    return super.close();
  }
}
