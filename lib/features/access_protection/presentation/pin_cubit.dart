import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/access_protection/domain/pin_hasher.dart';
import 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:local_auth/local_auth.dart';

/// PIN setup + verification with the escalating lockout ladder, plus biometric
/// unlock. There is no recovery path — see [PinRepository].
class PinCubit extends Cubit<PinConfig> {
  PinCubit(this._repo, {LocalAuthentication? localAuth})
    : _localAuth = localAuth ?? LocalAuthentication(),
      super(const PinConfig());

  final PinRepository _repo;
  final LocalAuthentication _localAuth;

  /// Loads the persisted config and re-applies the FLAG_SECURE window state.
  /// Window flags die with the activity and every recreation path re-runs the
  /// splash (which awaits this), so only a *set* is ever needed here — the
  /// no-PIN majority skips the channel round-trip on the launch critical path;
  /// [setup]/[disable] handle explicit clears.
  Future<void> load() async {
    final config = await _repo.load();
    if (config.secureScreen) {
      await _repo.setSecureScreen(enabled: true);
    }
    emit(config);
    // Housekeeping + anti-tamper: realign or clear a persisted lockout
    // against the monotonic clock. Free for the no-lockout majority (it
    // early-returns before any channel call).
    await reconcileLockout();
  }

  /// Realigns the persisted lockout with the authoritative (monotonic-when-
  /// valid) clock, so the wall-clock display the lock screen renders can
  /// never disagree with what [verify] enforces:
  ///  - lockout genuinely over (incl. cross-boot with wall expired) → cleared;
  ///  - wall stamp drifted from the monotonic truth (Settings clock moved
  ///    forward OR backward) → `lockedUntil` rewritten to now + remaining.
  /// Called from [load], on lock-screen entry, and inside [verify].
  Future<void> reconcileLockout() async {
    if (state.lockedUntil == null) return;
    final mono = await _repo.monotonicNow();
    final next = reconciled(
      state,
      DateTime.now(),
      elapsedMs: mono?.elapsedMs,
      bootCount: mono?.bootCount,
    );
    if (next == state) return;
    await _repo.save(next);
    emit(next);
  }

  /// Pure reconciliation (extracted for tests) — see [reconcileLockout].
  @visibleForTesting
  static PinConfig reconciled(
    PinConfig c,
    DateTime now, {
    int? elapsedMs,
    int? bootCount,
  }) {
    if (c.lockedUntil == null) return c;
    final remaining = c.lockoutRemainingAt(
      now,
      elapsedMs: elapsedMs,
      bootCount: bootCount,
    );
    if (remaining <= Duration.zero) return c.copyWith(clearLockout: true);
    // Only the monotonic leg can justify moving the wall stamp; while it is
    // invalid (cross-boot, off-Android) the wall clock IS the authority.
    if (c.monotonicLegValid(elapsedMs: elapsedMs, bootCount: bootCount)) {
      final expected = now.add(remaining);
      if (c.lockedUntil!.difference(expected).abs() >
          const Duration(seconds: 2)) {
        return c.copyWith(lockedUntil: expected);
      }
    }
    return c;
  }

  Future<void> setup({
    required PinType type,
    required String secret,
    required Set<PinScope> scopes,
    bool biometricEnabled = false,
    AutoLockTimeout autoLock = AutoLockTimeout.m1,
    bool secureScreen = false,
  }) async {
    // Regression fence: the UI enforces 4–10 digits, but a too-short secret
    // here would persist secretLength < 4 — and 0 deadlocks the keypad.
    // (Message deliberately excludes the secret.)
    if (type == PinType.custom && secret.length < 4) {
      throw ArgumentError('custom PIN must be at least 4 digits');
    }
    // Custom PINs are stored as a salted hash; Date/Time derive from the clock
    // and keep no secret at all.
    final salt = type == PinType.custom ? PinHasher.newSalt() : '';
    final config = PinConfig(
      type: type,
      secretHash: type == PinType.custom ? PinHasher.hash(salt, secret) : '',
      salt: salt,
      secretLength: type == PinType.custom ? secret.length : 0,
      scopes: scopes,
      biometricEnabled: biometricEnabled,
      autoLock: autoLock,
      secureScreen: secureScreen,
    );
    await _repo.save(config);
    await _repo.setSecureScreen(enabled: secureScreen);
    emit(config);
  }

  Future<void> disable() async {
    const config = PinConfig();
    await _repo.save(config);
    await _repo.setSecureScreen(enabled: false);
    emit(config);
  }

  /// Wall-clock millis of the last native screen-off (0 = never), for the
  /// [AutoLockTimeout.screenOff] resume decision.
  Future<int> lastScreenOff() => _repo.lastScreenOffMillis();

  /// Digit count that constitutes a complete entry for the active PIN type, so
  /// the lock screen can auto-submit at the right length (custom PINs may be
  /// 4–10 digits; DATE is `ddMMyyyy` = 8, TIME is `HHmm` = 4).
  int get expectedLength => switch (state.type) {
    // Floor at 4: a corrupted secretLength of 0 would otherwise swallow the
    // first keypress forever (0 >= 0) — a keypad no input can satisfy.
    PinType.custom => state.secretLength > 0 ? state.secretLength : 4,
    PinType.date => 8,
    PinType.time => 4,
    _ => 4,
  };

  /// Whether biometric/device-credential unlock is usable on this device, used
  /// to hide the biometric toggle where it isn't supported.
  Future<bool> canUseBiometrics() async {
    try {
      return await _localAuth.isDeviceSupported() &&
          await _localAuth.canCheckBiometrics;
    } on Exception {
      return false;
    }
  }

  /// Verifies [entry]; updates the retry/lockout state on failure.
  ///
  /// Enforcement uses the monotonic clock (EVO-015): `isLockedOut` alone is
  /// wall-clock and a Settings clock bump would clear the ladder. The
  /// reconcile step first realigns (and emits) the wall stamp, so when a
  /// tampered clock made the keypad reappear, the refusal below comes with
  /// the lockout UI restored rather than reading as "Incorrect PIN".
  Future<bool> verify(String entry) async {
    final mono = state.lockedUntil == null ? null : await _repo.monotonicNow();
    if (state.lockedUntil != null) {
      final next = reconciled(
        state,
        DateTime.now(),
        elapsedMs: mono?.elapsedMs,
        bootCount: mono?.bootCount,
      );
      if (next != state) {
        await _repo.save(next);
        emit(next);
      }
    }
    final config = state;
    if (config.isLockedOutAt(
      DateTime.now(),
      elapsedMs: mono?.elapsedMs,
      bootCount: mono?.bootCount,
    )) {
      return false;
    }

    final ok = matches(config, entry, DateTime.now());
    if (ok) {
      final reset = config.copyWith(retryCount: 0, clearLockout: true);
      await _repo.save(reset);
      emit(reset);
      return true;
    }

    final retries = config.retryCount + 1;
    final lockout = PinLockoutPolicy.lockoutFor(retries);
    // The monotonic reading is fetched lazily here: the common no-lockout
    // attempt paid no channel round-trip above.
    final anchor = lockout == null ? null : await _repo.monotonicNow();
    // clearLockout first: an escalating lockout must never keep a STALE
    // monotonic leg (e.g. the reading flaked to null this time) — an
    // already-expired old leg would override the fresh wall-clock lockout.
    final updated = config
        .copyWith(clearLockout: true)
        .copyWith(
          retryCount: retries,
          lockedUntil: lockout == null ? null : DateTime.now().add(lockout),
          lockoutElapsedUntilMs: anchor == null
              ? null
              : anchor.elapsedMs + lockout!.inMilliseconds,
          lockoutBootCount: anchor?.bootCount,
        );
    await _repo.save(updated);
    emit(updated);
    return false;
  }

  /// Whether [entry] matches the configured PIN at [now]. DATE/TIME derive
  /// from the clock; custom PINs compare against the salted hash (never
  /// plaintext). Static + clock-injected so tests can pin the time.
  @visibleForTesting
  static bool matches(PinConfig config, String entry, DateTime now) =>
      switch (config.type) {
        PinType.date || PinType.time => entry == derivedPin(config.type, now),
        PinType.custom => PinHasher.verify(
          config.salt,
          config.secretHash,
          entry,
        ),
        _ => false,
      };

  /// The clock-derived PIN for [PinType.date] (`ddMMyyyy`) / [PinType.time]
  /// (`HHmm`); null for types that store a real secret. Single source of
  /// truth for the matcher AND the setup screen's live preview — if these
  /// ever diverged, the preview would show a value that can't unlock.
  static String? derivedPin(PinType type, DateTime now) => switch (type) {
    PinType.date => '${_two(now.day)}${_two(now.month)}${now.year}',
    PinType.time => '${_two(now.hour)}${_two(now.minute)}',
    _ => null,
  };

  static String _two(int v) => v.toString().padLeft(2, '0');

  Future<bool> authenticateBiometric() async {
    try {
      final canCheck =
          await _localAuth.canCheckBiometrics ||
          await _localAuth.isDeviceSupported();
      if (!canCheck) return false;
      return await _localAuth.authenticate(
        localizedReason: 'Unlock Detoxo',
        persistAcrossBackgrounding: true,
      );
    } on Exception {
      return false;
    }
  }
}
