import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Thin wrapper over Hive (structured JSON) + secure storage (secrets).
/// A single seam for all local persistence so repositories stay simple.
class LocalStore {
  LocalStore._(this._box, this._secure);

  final Box<String> _box;
  final FlutterSecureStorage _secure;

  static const String _boxName = 'detoxo';

  static Future<LocalStore> create() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>(_boxName);
    const secure = FlutterSecureStorage();
    return LocalStore._(box, secure);
  }

  // ---- Plain (non-secret) JSON-string storage ----
  String? read(String key) => _box.get(key);
  Future<void> write(String key, String value) => _box.put(key, value);
  Future<void> delete(String key) => _box.delete(key);

  // ---- Secret storage ----
  Future<String?> readSecret(String key) => _secure.read(key: key);
  Future<void> writeSecret(String key, String value) =>
      _secure.write(key: key, value: value);
  Future<void> deleteSecret(String key) => _secure.delete(key: key);

  /// Wipes all local data — both the structured box and every secret. Used by
  /// "Reset app data"; after this the app re-bootstraps from defaults.
  Future<void> clearAll() async {
    await _box.clear();
    await _secure.deleteAll();
  }
}

/// Stable keys for [LocalStore].
abstract final class StoreKeys {
  static const String settings = 'app_settings';

  /// First-run step machine: the step reached plus every answer given so far,
  /// enums as stable name strings. Written on EVERY answer and before every
  /// step change, so a kill mid-onboarding resumes where the user left off.
  /// Completion is NOT here — that stays `AppSettings.onboarded`, so an
  /// existing install with no progress record is never re-onboarded.
  static const String onboardingProgress = 'onboarding_progress';
  static const String pinConfig = 'pin_config'; // secret
  static const String webBlocklist = 'web_blocklist';
  static const String webBlockStats = 'web_block_stats';
  static const String appBlocklist = 'app_blocklist';
  static const String protectedApps = 'protected_apps';
  static const String dailyLimit = 'daily_limit';
  static const String streak = 'daily_limit_streak';

  /// JSON array of rule documents (schedules, time limits, open limits);
  /// enums as stable name strings, capped at 50 rules.
  static const String rules = 'rules';

  /// Per-target temporary unblocks (M8): `{grants: [{targetType, targetId,
  /// startMs, endMs, cancelledMs, source}]}`, newest first, capped at 50 and
  /// pruned on write. Only the ACTIVE ones cross the channel; native enforces
  /// their expiry, so a grant lapses on time with Detoxo closed.
  static const String temporaryUnblocks = 'temporary_unblocks';

  /// The rationed-escape ledger (M8): `{config, entries: [{kind, atMs, untilMs,
  /// ruleId, reason}]}`, newest first, capped at 50.
  ///
  /// ONE store with a `kind` discriminator on purpose. M8 writes only
  /// `OVERRIDE` (lifting one locked rule); M2.2's emergency pass adds
  /// `EMERGENCY` to this same list rather than a second key — a persisted-key
  /// rename is a one-way door. Each preset reads only its own kind.
  static const String bypassLedger = 'bypass_ledger';

  /// Day-keyed insight rollups: `{days: {"dd-MM-yyyy": {...}}}`, pruned to the
  /// newest 90 days on every write. Day keys always come from `daySignature`.
  static const String usageDaily = 'usage_daily';
  static const String premiumDevUnlock = 'premium_dev_unlock';
  static const String analyticsEvents = 'analytics_events';
  static const String dismissedNotices = 'dismissed_notices';

  /// JSON list of `AppPermission.name`s that were granted on the last
  /// successful check — the permission gate's memory when a live read fails.
  static const String grantedPermissions = 'granted_permissions';

  /// Anonymous, random per-install id (UUID). Set as the Firebase Analytics /
  /// Crashlytics user id for per-install grouping; carries no PII.
  static const String installId = 'install_id';
}
