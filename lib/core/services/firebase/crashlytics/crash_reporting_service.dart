import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// App-facing crash / non-fatal error reporting surface. Behind an interface so
/// the `AppLogger` seam and features can report without importing Firebase
/// directly, and so it mocks cleanly in tests.
abstract interface class CrashReportingService {
  Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal,
  });

  /// Sets a custom key attached to every subsequent crash report.
  Future<void> setKey(String key, Object value);

  Future<void> setUserId(String id);
  Future<void> log(String message);
  Future<void> setCollectionEnabled({required bool enabled});
}

/// [CrashReportingService] backed by Firebase Crashlytics.
class FirebaseCrashReportingService implements CrashReportingService {
  FirebaseCrashReportingService({FirebaseCrashlytics? crashlytics})
    : _crashlytics = crashlytics ?? FirebaseCrashlytics.instance;

  final FirebaseCrashlytics _crashlytics;

  /// Routes uncaught Flutter-framework and platform/async errors to Crashlytics.
  /// Call once, as early as possible in `main` (before DI), so init-time crashes
  /// are captured. Static because it installs *global* handlers, not per-instance
  /// state, and must run before the DI container exists.
  static void installGlobalHandlers() {
    final crashlytics = FirebaseCrashlytics.instance;
    // A repeating error (e.g. a per-frame build/layout failure) must not
    // flood Crashlytics: every report copies its full stack onto the Java
    // heap, and a 60fps error loop OOM-killed the app on-device (2026-08-17).
    // Record each distinct error once per cooldown window.
    final recent = <int, DateTime>{};
    bool shouldRecord(Object error) {
      const cooldown = Duration(minutes: 5);
      final now = DateTime.now();
      recent.removeWhere((_, t) => now.difference(t) > cooldown);
      return identical(
        recent.putIfAbsent(error.toString().hashCode, () => now),
        now,
      );
    }

    FlutterError.onError = (details) {
      FlutterError.presentError(details); // keep console/IDE visibility
      if (shouldRecord(details.exception)) {
        crashlytics.recordFlutterFatalError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      if (shouldRecord(error)) {
        crashlytics.recordError(error, stack, fatal: true);
      }
      return true;
    };
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) => _crashlytics.recordError(error, stack, reason: reason, fatal: fatal);

  @override
  Future<void> setKey(String key, Object value) =>
      _crashlytics.setCustomKey(key, value);

  @override
  Future<void> setUserId(String id) => _crashlytics.setUserIdentifier(id);

  @override
  Future<void> log(String message) => _crashlytics.log(message);

  @override
  Future<void> setCollectionEnabled({required bool enabled}) =>
      _crashlytics.setCrashlyticsCollectionEnabled(enabled);
}
