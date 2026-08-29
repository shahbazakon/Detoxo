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

  /// Custom whole-app blocks push: a flat list of package names the native
  /// engine bounces HOME whenever they come to the foreground. Payload
  /// `{packages: List<String>}`; fail-safe like [pushProtectedApps].
  static const String pushAppBlocklist = 'pushAppBlocklist';

  /// Soft-nudge config push: the switch, the tuning and the apps it watches
  /// (the catalog's `distracting` behaviour — these are NOT blocked, only
  /// timed). Payload `{enabled: bool, packages: List of String,
  /// thresholdStepMs: int, dailyCap: int}`; each field is fail-safe like
  /// [pushProtectedApps] — an absent one leaves the stored value alone.
  static const String pushNudgeConfig = 'pushNudgeConfig';

  /// Rules push: the RESOLVED snapshot, not the stored rules — a JSON array
  /// with one entry per rule: flat `packages` / `domains` / `platformIds`
  /// (categories already flattened), absolute `windows: [[fromMs, untilMs]]`
  /// resolved 7 days ahead in the device zone, `always` and `reelTimeLimitMs`
  /// (the daily reel limit's native meter). Native does two long compares and
  /// a set lookup per event and parses no schedule. Payload `{json: String,
  /// nextBoundaryMs: Long}` — the earliest moment any window opens or closes
  /// (0 = none). Fail-safe like [pushWebBlocklist]: an absent / malformed
  /// `json` is a no-op, an unchanged one skips the refresh.
  static const String pushRules = 'pushRules';

  /// Per-target temporary unblocks (M8): the ACTIVE grants only, as a JSON
  /// array `[{targetType, targetId, endMs}]` — `targetType` is
  /// `REEL | APP | WEBSITE` and `targetId` a `platformId`, a package or a host.
  /// Payload `{json: String}`. Fail-safe like [pushWebBlocklist]: an absent or
  /// non-array `json` is a no-op (clearing needs an explicit `"[]"`), an
  /// unchanged one skips the refresh.
  ///
  /// `endMs` is an absolute wall stamp because it has to survive a reboot;
  /// native converts it to a monotonic deadline once per parse, so moving the
  /// system clock back cannot hold a grant open (EVO-048's rule, inherited from
  /// the per-site pause this replaces).
  static const String pushTemporaryUnblocks = 'pushTemporaryUnblocks';

  /// Reads AND CLEARS the target of a "Allow for a while" tap on the native
  /// wall, as `"TYPE|id"` (e.g. `"APP|com.instagram.android"`), or null.
  ///
  /// The wall's tap also foregrounds Detoxo, and on a cold start the
  /// EventChannel sink does not exist yet — so the `blockScreenAction` event it
  /// posts alongside is dropped, and this is how the target actually arrives.
  /// Consumed exactly once, so a re-read never re-offers a stale bypass.
  static const String takePendingUnblock = 'takePendingUnblock';

  /// Reads AND CLEARS the grants the user took **on the wall itself**
  /// (EVO-050), as the `pushTemporaryUnblocks` array shape. Native enforces
  /// them immediately; this is how Hive — which owns the history and is what
  /// the next push rewrites from — learns about them before it would otherwise
  /// overwrite them away.
  static const String takeNativeGrants = 'takeNativeGrants';

  // Permission + service status queries.
  static const String isAccessibilityEnabled = 'isAccessibilityEnabled';
  static const String serviceAlive = 'serviceAlive';
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

  /// Whether Detoxo's notification listener is enabled in Settings.Secure —
  /// the grant behind notification suppression. Returns `Boolean`; read
  /// tri-state by the permission repository, never as a bare false.
  static const String isNotificationListenerEnabled =
      'isNotificationListenerEnabled';

  /// Opens the system "Notification access" screen. Returns `Boolean` (launch
  /// ok). There is no programmatic grant for this one — the user must toggle
  /// Detoxo on there themselves.
  static const String openNotificationListenerSettings =
      'openNotificationListenerSettings';

  // Usage stats — pull-only reads of the OS's UsageStatsManager (no ticker,
  // no cache; callers batch by day). The ONLY two arms that throw.
  /// Per-app foreground time in `[startMillis, endMillis)`. Payload
  /// `{startMillis, endMillis}`; returns `List<{package, foregroundMillis}>`,
  /// `foregroundMillis > 0` only. Throws `PlatformException("USAGE_ACCESS_DENIED")`
  /// without the grant and `("BAD_ARGS")` on missing/inverted bounds — an
  /// empty list would read as a quiet day, not as "not allowed to look"
  /// (EVO-014).
  static const String queryAppUsage = 'queryAppUsage';

  /// Foreground / pickup events in `[startMillis, endMillis)`, ascending.
  /// Returns `List<{package, type: 1 | 18, timestampMillis}>` (1 =
  /// MOVE_TO_FOREGROUND, 18 = SCREEN_INTERACTIVE; everything else is dropped
  /// natively). Same payload and errors as [queryAppUsage].
  static const String queryUsageEvents = 'queryUsageEvents';

  // PIN lock / Smart Auto Lock.
  /// Toggle FLAG_SECURE on the activity window (hide in Recents + block
  /// screenshots). Payload `{enabled}`.
  static const String setSecureScreen = 'setSecureScreen';

  /// Wall-clock millis of the last `ACTION_SCREEN_OFF` seen this process
  /// (0 = never). Drives the "when screen turns off" auto-lock option.
  static const String lastScreenOff = 'lastScreenOff';

  /// The monotonic clocks: `{elapsedMs: SystemClock.elapsedRealtime(),
  /// bootCount: Settings.Global.BOOT_COUNT (-1 if unreadable)}`. Immune to
  /// Settings clock changes; the boot count makes cross-boot readings
  /// detectable. Anchors the PIN lockout.
  static const String monotonicNow = 'monotonicNow';

  // Block actions (used for testing the engine and PIN/one-reel UI).
  static const String performBack = 'performBack';
  static const String killApp = 'killApp';
  static const String lockScreen = 'lockScreen';

  // Block screen (intervention wall). The four native trigger sites raise the
  // wall in-process; these arms exist for the Dart-driven cases (a style
  // preview from the editor) and mirror the block actions above.
  /// Raise the wall with a payload map (see `BlockScreenPayload.toWire`).
  /// Returns `true` when the window is up, `false` when the wall is switched
  /// off, the overlay grant is missing, or the payload is unusable.
  static const String showBlockScreen = 'showBlockScreen';
  static const String hideBlockScreen = 'hideBlockScreen';
  static const String isBlockScreenShowing = 'isBlockScreenShowing';

  /// Eject to the launcher (`ACTION_MAIN` + `CATEGORY_HOME`).
  static const String goHome = 'goHome';

  /// Persist the wall's appearance + on/off switch. Payload `{style: Map}`
  /// (see `BlockScreenStyle.toWire`); a showing wall is rebuilt live.
  static const String setBlockScreenStyle = 'setBlockScreenStyle';

  /// The persisted style as a map (`{}` when never saved) — the editor's
  /// hydrate; native prefs are the single source of truth.
  static const String blockScreenStyle = 'blockScreenStyle';

  // Device info / stats.
  static const String deviceInfo = 'deviceInfo';
  static const String blockStats = 'blockStats';

  // Installed user-launchable apps (drives the install-aware blocklist).
  static const String installedPackages = 'installedPackages';

  /// Installed launchable apps with label + 96px PNG icon bytes (drives the
  /// add-app picker). Returns `List<{package, label, icon: Uint8List?}>`.
  static const String installedApps = 'installedApps';

  /// EVO-047: installed browsers the web blocker CANNOT enforce in — those
  /// outside native `BrowserUrlExtractor.KNOWN_BROWSERS`. Returns
  /// `List<{packageName, label}>`, empty when everything installed is covered.
  static const String unsupportedBrowsers = 'unsupportedBrowsers';

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
  static const String blocked = 'blocked';

  /// A blocked website was detected in a browser and backed out of.
  /// Payload: `{source: "RULE" | "ADULT", mode, today, total, host?}` — `host`
  /// is present only for `RULE` hits (the user's own blocklist); adult-list
  /// blocks are counted but never named (EVO-018).
  static const String webBlocked = 'webBlocked';

  /// Live Conscious bank update (bankMs / maxBankMs / watching / blocked).
  static const String consciousState = 'consciousState';

  /// Live One Reel / Unblock session update. Payload: `{consumed, allowance,
  /// blocked, active}`.
  static const String reelSessionState = 'reelSessionState';

  /// A short video was counted. Payload: `{package, today, total, perAppToday,
  /// perAppTotal, timeTodayMs, enabled, bubbleEnabled}`.
  static const String contentCounted = 'contentCounted';

  /// The user touched an action on the block screen. Payload: `{action:
  /// "GO_HOME" | "OPEN_APP" | "DISMISS" | "UNBLOCK", referenceType,
  /// referenceId, preview: bool}` — `preview` is true for the editor's "Try
  /// it" wall. `referenceId` (a host / package) is never forwarded to
  /// analytics. Not sticky.
  ///
  /// `UNBLOCK` reaches analytics through here, but the M8 flow it starts does
  /// NOT: the target arrives through [ChannelMethods.takePendingUnblock], which
  /// survives the cold start this event does not.
  static const String blockScreenAction = 'blockScreenAction';

  /// A pushed rule window opened or closed: native passed `nextBoundaryMs`
  /// (checked on window-state changes and the 15-min watchdog tick) and
  /// posts this once, then clears it. Payload `{atMs}`. Dart re-resolves and
  /// re-pushes. Not sticky — dropped when no Dart listener is attached.
  static const String ruleBoundary = 'ruleBoundary';

  /// A soft-nudge card was shown. Payload `{package, elapsedMs, thresholdMs}`
  /// — `elapsedMs` is the real time in the app, `thresholdMs` the multiple
  /// that was crossed. Not sticky.
  static const String nudgeShown = 'nudgeShown';
}
