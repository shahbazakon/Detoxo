import 'package:detoxo/core/services/firebase/analytics/analytics_service.dart';
import 'package:detoxo/core/services/firebase/analytics/native_event_reporter.dart';
import 'package:detoxo/core/services/firebase/crashlytics/crash_reporting_service.dart';
import 'package:detoxo/core/services/firebase/performance/performance_service.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';

/// Single entry point that switches on the Firebase telemetry layer once the app
/// is initialised and DI is ready. Kept thin: it wires the cross-cutting
/// concerns (collection flags, the anonymous install id, the `AppLogger` →
/// Crashlytics seam, the native-event subscription) that don't belong to any one
/// service. The global crash handlers are installed separately and earlier — see
/// [FirebaseCrashReportingService.installGlobalHandlers].
abstract final class FirebaseServices {
  /// Enables collection (this build collects in every flavour), assigns the
  /// stable anonymous install id, forwards `AppLogger.e` to Crashlytics as
  /// non-fatal reports, and starts the native-event reporter. Call once, after
  /// `configureDependencies()` and before `runApp`.
  static Future<void> start(GetIt sl) async {
    final analytics = sl<AnalyticsService>();
    final crash = sl<CrashReportingService>();
    final performance = sl<PerformanceService>();

    await analytics.setCollectionEnabled(enabled: true);
    await crash.setCollectionEnabled(enabled: true);
    await performance.setCollectionEnabled(enabled: true);

    final installId = await _installId(sl<LocalStore>());
    await analytics.setUserId(installId);
    await crash.setUserId(installId);

    // Bridge the app-wide logging seam to Crashlytics (non-fatal reports).
    // Redacted on the way out — see [_offDevice].
    AppLogger.onError = (message, error, stack) {
      crash.recordError(offDevice(error) ?? message, stack, reason: message);
    };

    sl<FirebaseNativeEventReporter>().start();
  }

  /// The one place an error object crosses the network boundary, so the one
  /// place it has to be scrubbed.
  ///
  /// `FormatException.toString()` embeds a ~78-character window of its
  /// **source string**. Five repositories log a decode failure as
  /// `AppLogger.e(msg, e)` — and the blob being decoded is the user's own data:
  /// the protected-apps list (`protected_apps_repository_impl.dart`, whose whole
  /// promise is that it never leaves the device — see
  /// `docs/code_docs/24-protected-apps.md` §6), per-app screen time
  /// (`insights_repository_impl.dart`), the blocked hosts and packages behind
  /// the rules, and app settings. Uploading that window would ship package
  /// names like a banking app straight to Firebase.
  ///
  /// So a `FormatException` is reduced to its type, its message ("Unexpected
  /// character") and its offset — enough to debug a corrupt document, nothing
  /// about its contents. Local `debugPrint` in [AppLogger] keeps the full
  /// detail; only this path is redacted. Every other error passes through: the
  /// leak is specific to exceptions that carry their input.
  @visibleForTesting
  static Object? offDevice(Object? error) {
    if (error is! FormatException) return error;
    final offset = error.offset;
    return 'FormatException: ${error.message}'
        '${offset == null ? '' : ' (at offset $offset)'}';
  }

  /// Reads the anonymous install id, generating and persisting one on first run.
  /// A random UUID — never anything derived from the device or the user.
  static Future<String> _installId(LocalStore store) async {
    final existing = store.read(StoreKeys.installId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await store.write(StoreKeys.installId, id);
    return id;
  }
}
