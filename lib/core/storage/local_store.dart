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
  static const String pinConfig = 'pin_config'; // secret
  static const String webBlocklist = 'web_blocklist';
  static const String webBlockStats = 'web_block_stats';
  static const String appBlocklist = 'app_blocklist';
  static const String protectedApps = 'protected_apps';
  static const String dailyLimit = 'daily_limit';
  static const String streak = 'daily_limit_streak';
  static const String premiumDevUnlock = 'premium_dev_unlock';
  static const String analyticsEvents = 'analytics_events';
  static const String dismissedNotices = 'dismissed_notices';

  /// Anonymous, random per-install id (UUID). Set as the Firebase Analytics /
  /// Crashlytics user id for per-install grouping; carries no PII.
  static const String installId = 'install_id';
}
