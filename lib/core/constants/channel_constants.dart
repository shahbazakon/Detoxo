/// Names of the platform channels bridging Dart and native Android.
///
/// The native `AccessibilityService` hosts the hot detection/block path; Dart
/// drives configuration and reads a live event/status stream.
abstract final class Channels {
  /// MethodChannel: Dart → native commands (push config, set plan, query
  /// permissions, kill/lock, overlay control).
  static const String commands = 'com.errorxperts.detoxo/commands';

  /// EventChannel: native → Dart stream (service status, detections, foreground
  /// app changes).
  static const String events = 'com.errorxperts.detoxo/events';
}

/// Command method names invoked on [Channels.commands].
abstract final class ChannelMethods {
  // Config / settings push (cross-process persisted on the native side).
  static const String pushConfig = 'pushConfig';
  static const String pushSettings = 'pushSettings';

  /// Website blocklist push: a small JSON list of `{pattern, matchType}` rules
  /// the native `WebBlockEngine` matches browser URLs against.
  static const String pushWebBlocklist = 'pushWebBlocklist';

  /// Privacy-protected apps push: a flat list of package names the native
  /// engine must completely ignore (no counting, reading, or blocking while
  /// one is foreground). Payload `{packages: List<String>}`.
  static const String pushProtectedApps = 'pushProtectedApps';

  // Permission + service status queries.
  static const String isAccessibilityEnabled = 'isAccessibilityEnabled';
  static const String openAccessibilitySettings = 'openAccessibilitySettings';
  static const String canDrawOverlays = 'canDrawOverlays';
  static const String requestOverlayPermission = 'requestOverlayPermission';
  static const String hasUsageAccess = 'hasUsageAccess';
  static const String openUsageAccessSettings = 'openUsageAccessSettings';
  static const String isIgnoringBatteryOptimizations =
      'isIgnoringBatteryOptimizations';
  static const String requestIgnoreBatteryOptimizations =
      'requestIgnoreBatteryOptimizations';
  static const String isDeviceAdminActive = 'isDeviceAdminActive';
  static const String requestDeviceAdmin = 'requestDeviceAdmin';
  static const String removeDeviceAdmin = 'removeDeviceAdmin';

  // PIN lock / Smart Auto Lock.
  /// Toggle FLAG_SECURE on the activity window (hide in Recents + block
  /// screenshots). Payload `{enabled}`.
  static const String setSecureScreen = 'setSecureScreen';

  /// Wall-clock millis of the last `ACTION_SCREEN_OFF` seen this process
  /// (0 = never). Drives the "when screen turns off" auto-lock option.
  static const String lastScreenOff = 'lastScreenOff';

  // Block actions / overlay (used for testing the engine and PIN/one-reel UI).
  static const String performBack = 'performBack';
  static const String killApp = 'killApp';
  static const String lockScreen = 'lockScreen';
  static const String showOverlay = 'showOverlay';
  static const String hideOverlay = 'hideOverlay';

  // Device / foreground info.
  static const String foregroundPackage = 'foregroundPackage';
  static const String deviceInfo = 'deviceInfo';
  static const String blockStats = 'blockStats';

  // Installed user-launchable apps (drives the install-aware blocklist).
  static const String installedPackages = 'installedPackages';

  /// Installed launchable apps with label + 96px PNG icon bytes (drives the
  /// add-app picker). Returns `List<{package, label, icon: Uint8List?}>`.
  static const String installedApps = 'installedApps';

  // Conscious (earn-as-you-abstain) bank snapshot.
  static const String consciousState = 'consciousState';

  /// Reset the Conscious bank to empty (fresh start). Fired only on a genuine
  /// user entry to Conscious — an auto-revert into Conscious keeps the bank.
  static const String resetConsciousBank = 'resetConsciousBank';

  /// One Reel / Unblock: (re)arm the reel session with a fresh allowance,
  /// resetting the native consumed-count. Payload `{count}` (1..20). Imperative
  /// so an unrelated settings push never re-arms mid-session.
  static const String armReelSession = 'armReelSession';

  /// One-shot pull of the reel-session state (`{consumed, allowance, blocked,
  /// active}`).
  static const String reelSessionState = 'reelSessionState';

  // Short-video / reel counter.
  static const String contentCounterSnapshot = 'contentCounterSnapshot';
  static const String setContentCounterEnabled = 'setContentCounterEnabled';
  static const String setContentBubbleEnabled = 'setContentBubbleEnabled';
  static const String pinContentWidget = 'pinContentWidget';
  static const String refreshContentWidget = 'refreshContentWidget';

  /// Push bubble and/or home-widget appearance to native. Payload `{bubble?,
  /// widget?}` (each a style wire map); native persists it, live-re-renders the
  /// visible bubble, and re-renders every pinned widget.
  static const String setCounterStyle = 'setCounterStyle';
}

/// Event `type` values streamed over [Channels.events].
abstract final class ChannelEvents {
  static const String serviceStatus = 'serviceStatus';
  static const String detection = 'detection';
  static const String blocked = 'blocked';

  /// A blocked website was detected in a browser and backed out of.
  /// Payload: `{host, mode, today, total}`.
  static const String webBlocked = 'webBlocked';
  static const String foregroundChanged = 'foregroundChanged';

  /// Live Conscious bank update (bankMs / maxBankMs / watching / blocked).
  static const String consciousState = 'consciousState';

  /// Live One Reel / Unblock session update. Payload: `{consumed, allowance,
  /// blocked, active}`.
  static const String reelSessionState = 'reelSessionState';

  /// A short video was counted. Payload: `{package, today, total, perAppToday,
  /// perAppTotal}`.
  static const String contentCounted = 'contentCounted';
}
