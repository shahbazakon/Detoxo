import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/conscious_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/reel_session_state.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_notice.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';

// Surface the contract's own parameter/return types to consumers.
export 'package:detoxo/core/platform_channels/installed_app.dart';

/// Loads the detection config (offline bundle, refreshed remotely) and exposes
/// it as user-facing block targets.
abstract interface class ConfigRepository {
  /// Builds the user-facing block targets from the catalog.
  ///
  /// When [installedPackages] is non-null, targets are made install-aware: each
  /// is tagged [BlockTarget.isInstalled], uninstalled apps that aren't flagged
  /// `showIfNotInstalled` are dropped, and installed apps sort first. Passing
  /// `null` (off-Android / install state unknown) returns the full catalog with
  /// everything marked installed.
  Future<List<BlockTarget>> loadBlockTargets({Set<String>? installedPackages});

  /// The raw platforms-config JSON to push to the native engine.
  Future<String> rawConfigJson();

  /// Default in-app notices parsed from initial_config.
  Future<List<AppNotice>> loadNotices();
}

/// Persists and streams the user's [AppSettings].
abstract interface class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
  Stream<AppSettings> watch();
}

/// The native engine bridge (MethodChannel + EventChannel).
abstract interface class EngineRepository {
  Stream<ServiceSnapshot> statusStream();
  Stream<BlockEvent> blockStream();

  /// Live Conscious bank updates streamed from the native accountant.
  Stream<ConsciousState> consciousStream();

  /// Live One Reel / Unblock session updates streamed from the native engine.
  Stream<ReelSessionState> reelSessionStream();

  Future<void> pushConfig(String configJson);
  Future<void> pushSettings(AppSettings settings);

  /// Pushes the active website blocklist (JSON `[{pattern, matchType}]`) to the
  /// native engine's URL matcher.
  Future<void> pushWebBlocklist(String json);

  /// Pushes the enabled privacy-protected package names — apps the native
  /// engine must completely ignore while they are foreground.
  Future<void> pushProtectedApps(List<String> packages);

  /// Pushes the enabled custom whole-app-block package names — apps the native
  /// engine bounces HOME whenever they come to the foreground.
  Future<void> pushAppBlocklist(List<String> packages);

  Future<ServiceSnapshot> currentStatus();

  /// One-shot pull of the current Conscious bank (for initial UI render).
  Future<ConsciousState> consciousCurrent();

  /// Resets the native Conscious bank to empty. Called only on a genuine user
  /// entry to Conscious (an auto-revert into Conscious keeps the earned bank).
  Future<void> resetConsciousBank();

  /// (Re)arms a fresh reel allowance of [count] (1..20), resetting the native
  /// consumed-count. Called on every One Reel / Unblock mode tap.
  Future<void> armReelSession(int count);

  /// One-shot pull of the current One Reel / Unblock session (for initial UI).
  Future<ReelSessionState> reelSessionCurrent();

  Future<void> performBack();
  Future<void> killApp(String packageName);
  Future<void> lockScreen();

  /// Package names of the device's user-launchable apps, or `null` when install
  /// state can't be determined (off-Android / channel error).
  Future<Set<String>?> installedPackages();

  /// The device's user-launchable apps with label + icon for the add-app
  /// picker, or `null` when unknown (off-Android / channel error). Cached
  /// after the first successful scan; [refresh] forces a rescan.
  Future<List<InstalledApp>?> installedApps({bool refresh = false});
}
