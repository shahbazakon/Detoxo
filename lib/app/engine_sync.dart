import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';

/// Pushes every Dart-owned blocklist to the native engine: protected apps,
/// the merged web blocklist, the custom whole-app blocks and the soft-nudge
/// config (not a blocklist, but the same drift problem). The single
/// definition of "repair engine drift" — called from the bootstrap (cold start)
/// and the resume heavy leg, which used to carry verbatim copies of this.
/// (The rules snapshot is pushed by the app-wide `RulesCubit`: on load, on
/// every resume via `AppResumeSync`, on every edit and on `ruleBoundary`.)
///
/// Each sync is individually fail-safe (a failed load aborts its own push);
/// a failure here is logged, never rethrown — so callers may fire-and-forget
/// without leaking uncaught-zone errors.
Future<void> syncEngineBlocklists() => Future.wait([
  guardedSync(
    'protectedApps',
    syncProtectedAppsAtBoot(
      sl<ProtectedAppsRepository>(),
      sl<EngineRepository>(),
    ),
  ),
  guardedSync(
    'webBlocklist',
    syncWebBlocklist(
      sl<WebBlockRepository>(),
      sl<SettingsRepository>(),
      sl<AppBlockRepository>(),
      sl<EngineRepository>(),
    ),
  ),
  guardedSync(
    'appBlocklist',
    syncAppBlocklist(sl<AppBlockRepository>(), sl<EngineRepository>()),
  ),
  guardedSync(
    'nudge',
    syncNudgeConfig(sl<SettingsRepository>(), sl<EngineRepository>()),
  ),
]).then((_) {});

/// Awaits [task], converting a failure into a log line instead of an
/// uncaught-zone error (fire-and-forget sync legs otherwise surface as
/// Crashlytics noise with no context).
Future<void> guardedSync(String what, Future<void> task) async {
  try {
    await task;
  } on Object catch (e) {
    AppLogger.e('engine sync $what failed', e);
  }
}
