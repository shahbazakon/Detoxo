import 'dart:async';

import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:flutter/services.dart';

/// Low-level wrapper over the native command MethodChannel and the engine
/// EventChannel. Repositories build on top of this; it owns no domain logic.
class EngineChannel {
  EngineChannel()
    : _commands = const MethodChannel(Channels.commands),
      _events = const EventChannel(Channels.events);

  final MethodChannel _commands;
  final EventChannel _events;

  Stream<Map<String, dynamic>>? _eventStream;

  /// Broadcast stream of native engine events (status / detection / blocked).
  ///
  /// Off-Android there is no native engine, so the stream is empty (subscribing
  /// to the EventChannel would otherwise emit a logged error every launch).
  ///
  /// Self-healing: the underlying EventChannel stream can close (native engine
  /// detach/recreation). Every cubit holds one process-lifetime subscription to
  /// this stream, so a silent close would freeze live counters and status
  /// forever — on done, the channel is re-subscribed after a short delay.
  Stream<Map<String, dynamic>> events() {
    if (!PlatformCapabilities.supportsBlockingEngine) {
      return const Stream<Map<String, dynamic>>.empty();
    }
    if (_eventStream == null) {
      final controller = StreamController<Map<String, dynamic>>.broadcast();
      _eventStream = controller.stream;
      _connectEvents(controller);
    }
    return _eventStream!;
  }

  void _connectEvents(StreamController<Map<String, dynamic>> controller) {
    _events.receiveBroadcastStream().listen(
      (dynamic e) {
        // A malformed payload must log like a stream error, not escape the
        // onData callback as an uncaught zone error.
        try {
          controller.add(Map<String, dynamic>.from(e as Map));
        } on Object catch (error) {
          AppLogger.e('engine event bad payload', error);
        }
      },
      onError: (Object error) =>
          AppLogger.e('engine event stream error', error),
      onDone: () => Future<void>.delayed(
        const Duration(seconds: 1),
        () => _connectEvents(controller),
      ),
    );
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    // No native engine off-Android: short-circuit so screens render with safe
    // defaults instead of paying a MissingPluginException round-trip per call.
    if (!PlatformCapabilities.supportsBlockingEngine) return null;
    try {
      return await _commands.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      AppLogger.e('channel $method failed', e);
      return null;
    } on MissingPluginException {
      // Running on a platform without the native side (e.g. tests / iOS).
      return null;
    }
  }

  /// Like [_invoke], but a [PlatformException] propagates instead of
  /// collapsing into null. For the few arms whose "no" must stay
  /// distinguishable from "didn't answer" (usage stats: denied vs unavailable,
  /// EVO-014). Still null off-Android / without the native side.
  Future<T?> invokeOrThrow<T>(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!PlatformCapabilities.supportsBlockingEngine) return null;
    try {
      return await _commands.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> invokeBool(String method, [Map<String, dynamic>? args]) async =>
      (await _invoke<bool>(method, args)) ?? false;

  /// Tri-state variant of [invokeBool]: null means "the call didn't answer"
  /// (channel error / no native side), NOT "the OS said no". Permission checks
  /// use this so one flaky read can't masquerade as a revoked grant.
  Future<bool?> invokeBoolOrNull(String method) => _invoke<bool>(method);

  Future<void> invokeVoid(String method, [Map<String, dynamic>? args]) async =>
      _invoke<void>(method, args);

  Future<Map<String, dynamic>> invokeMap(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final res = await _invoke<Map<dynamic, dynamic>>(method, args);
    return res == null ? <String, dynamic>{} : Map<String, dynamic>.from(res);
  }

  // Convenience wrappers used across repositories.
  Future<void> pushConfig(String json) =>
      invokeVoid(ChannelMethods.pushConfig, {'json': json});

  Future<void> pushSettings(Map<String, dynamic> settings) =>
      invokeVoid(ChannelMethods.pushSettings, settings);

  /// Pushes the website blocklist (JSON-encoded `[{pattern, matchType}]`) to the
  /// native engine.
  Future<void> pushWebBlocklist(String json) =>
      invokeVoid(ChannelMethods.pushWebBlocklist, {'json': json});

  /// Pushes the enabled privacy-protected package names; native persists them
  /// and the service ignores those apps entirely. No-op off-Android.
  Future<void> pushProtectedApps(List<String> packages) =>
      invokeVoid(ChannelMethods.pushProtectedApps, {'packages': packages});

  /// Pushes the enabled custom whole-app-block package names; native persists
  /// them and bounces those apps HOME on open. No-op off-Android.
  Future<void> pushAppBlocklist(List<String> packages) =>
      invokeVoid(ChannelMethods.pushAppBlocklist, {'packages': packages});

  /// Pushes the soft-nudge config: the switch, the apps it times and its
  /// tuning. See [ChannelMethods.pushNudgeConfig]. No-op off-Android.
  Future<void> pushNudgeConfig({
    required bool enabled,
    required List<String> packages,
    required int thresholdStepMs,
    required int dailyCap,
  }) => invokeVoid(ChannelMethods.pushNudgeConfig, {
    'enabled': enabled,
    'packages': packages,
    'thresholdStepMs': thresholdStepMs,
    'dailyCap': dailyCap,
  });

  /// Pushes the resolved rules snapshot (JSON array, see
  /// [ChannelMethods.pushRules]) and the earliest window edge (0 = none);
  /// native enforces the windows itself. No-op off-Android.
  Future<void> pushRules(String json, int nextBoundaryMs) => invokeVoid(
    ChannelMethods.pushRules,
    {'json': json, 'nextBoundaryMs': nextBoundaryMs},
  );

  /// The ACTIVE per-target temporary unblocks (M8) as a JSON array of
  /// `{targetType, targetId, endMs}`; native enforces their expiry. No-op
  /// off-Android.
  Future<void> pushTemporaryUnblocks(String json) =>
      invokeVoid(ChannelMethods.pushTemporaryUnblocks, {'json': json});

  /// The target of an "Allow for a while" tap on the native wall (`"TYPE|id"`)
  /// — read AND cleared natively, so it answers at most once.
  Future<String?> takePendingUnblock() =>
      _invoke<String>(ChannelMethods.takePendingUnblock);

  /// Grants taken on the wall itself (EVO-050), as the `pushTemporaryUnblocks`
  /// JSON array — read AND cleared natively, so each is absorbed once.
  Future<String?> takeNativeGrants() =>
      _invoke<String>(ChannelMethods.takeNativeGrants);

  Future<bool> isAccessibilityEnabled() =>
      invokeBool(ChannelMethods.isAccessibilityEnabled);

  /// Whether the accessibility service INSTANCE is live. Distinct from
  /// [isAccessibilityEnabled] (the Settings.Secure string): some OEMs
  /// (ColorOS force-stop) kill the service while the setting stays enabled.
  Future<bool> serviceAlive() => invokeBool(ChannelMethods.serviceAlive);

  Future<void> openAccessibilitySettings() =>
      invokeVoid(ChannelMethods.openAccessibilitySettings);

  Future<bool> canDrawOverlays() => invokeBool(ChannelMethods.canDrawOverlays);
  Future<void> requestOverlay() =>
      invokeVoid(ChannelMethods.requestOverlayPermission);

  // The boolean permission QUERIES have no wrappers here: the permission
  // repository reads them tri-state via [invokeBoolOrNull] directly.
  Future<void> openUsageAccess() =>
      invokeVoid(ChannelMethods.openUsageAccessSettings);

  Future<void> requestIgnoreBattery() =>
      invokeVoid(ChannelMethods.requestIgnoreBatteryOptimizations);

  Future<void> openNotificationListenerSettings() =>
      invokeVoid(ChannelMethods.openNotificationListenerSettings);

  // ── Usage stats (pull-only) ───────────────────────────────────────────────

  /// Raw `{package, foregroundMillis}` rows, or null off-Android. Throws the
  /// `USAGE_ACCESS_DENIED` / `BAD_ARGS` [PlatformException]s through — the
  /// usage repository maps them; nothing else should call this directly.
  Future<List<Map<String, dynamic>>?> queryAppUsage({
    required int startMillis,
    required int endMillis,
  }) => _invokeRows(ChannelMethods.queryAppUsage, {
    'startMillis': startMillis,
    'endMillis': endMillis,
  });

  /// Raw `{package, type, timestampMillis}` rows; same contract as
  /// [queryAppUsage].
  Future<List<Map<String, dynamic>>?> queryUsageEvents({
    required int startMillis,
    required int endMillis,
  }) => _invokeRows(ChannelMethods.queryUsageEvents, {
    'startMillis': startMillis,
    'endMillis': endMillis,
  });

  Future<List<Map<String, dynamic>>?> _invokeRows(
    String method,
    Map<String, dynamic> args,
  ) async {
    final res = await invokeOrThrow<List<dynamic>>(method, args);
    return res?.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> requestDeviceAdmin() =>
      invokeVoid(ChannelMethods.requestDeviceAdmin);
  Future<void> removeDeviceAdmin() =>
      invokeVoid(ChannelMethods.removeDeviceAdmin);

  /// Applies/clears FLAG_SECURE on the activity window (PIN lock's "hide in
  /// Recents & block screenshots"). No-op off-Android.
  Future<void> setSecureScreen({required bool enabled}) =>
      invokeVoid(ChannelMethods.setSecureScreen, {'enabled': enabled});

  /// Wall-clock millis of the last native `ACTION_SCREEN_OFF` (0 = never seen
  /// / off-Android).
  Future<int> lastScreenOff() async =>
      (await _invoke<int>(ChannelMethods.lastScreenOff)) ?? 0;

  /// Monotonic millis since boot (`SystemClock.elapsedRealtime()`) plus the
  /// `BOOT_COUNT` they belong to, or null off-Android / on a channel error /
  /// where the boot count is unreadable. Callers fall back to the wall clock.
  Future<({int elapsedMs, int bootCount})?> monotonicNow() async {
    final res = await _invoke<Map<dynamic, dynamic>>(
      ChannelMethods.monotonicNow,
    );
    final elapsed = res?['elapsedMs'] as int?;
    final boot = res?['bootCount'] as int?;
    if (elapsed == null || boot == null || boot < 0) return null;
    return (elapsedMs: elapsed, bootCount: boot);
  }

  Future<void> performBack() => invokeVoid(ChannelMethods.performBack);
  Future<void> killApp(String pkg) =>
      invokeVoid(ChannelMethods.killApp, {'package': pkg});
  Future<void> lockScreen() => invokeVoid(ChannelMethods.lockScreen);

  // ── Block screen (intervention wall) ──────────────────────────────────────

  /// Raises the wall with a `BlockScreenPayload.toWire()` map. False when it
  /// is switched off, the overlay grant is missing, or off-Android.
  Future<bool> showBlockScreen(Map<String, dynamic> payload) =>
      invokeBool(ChannelMethods.showBlockScreen, payload);
  Future<void> hideBlockScreen() => invokeVoid(ChannelMethods.hideBlockScreen);
  Future<bool> isBlockScreenShowing() =>
      invokeBool(ChannelMethods.isBlockScreenShowing);
  Future<void> goHome() => invokeVoid(ChannelMethods.goHome);

  /// Persists the wall's style (`BlockScreenStyle.toWire()`); a showing wall
  /// is rebuilt live. No-op off-Android.
  Future<void> setBlockScreenStyle(Map<String, dynamic> style) =>
      invokeVoid(ChannelMethods.setBlockScreenStyle, {'style': style});

  /// The persisted wall style as a map; `{}` when never saved / off-Android.
  Future<Map<String, dynamic>> blockScreenStyle() =>
      invokeMap(ChannelMethods.blockScreenStyle);

  Future<Map<String, dynamic>> blockStats() =>
      invokeMap(ChannelMethods.blockStats);

  Future<Map<String, dynamic>> consciousState() =>
      invokeMap(ChannelMethods.consciousState);

  /// Resets the Conscious bank to empty. Called only on a genuine user entry to
  /// Conscious (not on an auto-revert, which keeps the earned bank).
  Future<void> resetConsciousBank() =>
      invokeVoid(ChannelMethods.resetConsciousBank);

  // ── One Reel / Unblock ────────────────────────────────────────────────────

  /// (Re)arms a fresh reel allowance of [count] (1..20), resetting the native
  /// consumed-count. Imperative — called on every mode tap.
  Future<void> armReelSession(int count) =>
      invokeVoid(ChannelMethods.armReelSession, {'count': count});

  /// One-shot pull of the reel-session state (`{consumed, allowance, blocked,
  /// active}`). Empty off-Android.
  Future<Map<String, dynamic>> reelSessionState() =>
      invokeMap(ChannelMethods.reelSessionState);

  // ── Short-video / reel counter ────────────────────────────────────────────

  /// One-shot pull of the counter snapshot (`{enabled, today, total, date,
  /// perAppToday, perAppTotal}`). Empty off-Android.
  Future<Map<String, dynamic>> contentCounterSnapshot() =>
      invokeMap(ChannelMethods.contentCounterSnapshot);

  Future<void> setContentCounterEnabled({required bool enabled}) =>
      invokeVoid(ChannelMethods.setContentCounterEnabled, {'enabled': enabled});

  Future<void> setContentBubbleEnabled({required bool enabled}) =>
      invokeVoid(ChannelMethods.setContentBubbleEnabled, {'enabled': enabled});

  /// Requests the launcher pin the reel counter widget. Returns false if the
  /// launcher doesn't support pinning (or off-Android).
  Future<bool> pinContentWidget() =>
      invokeBool(ChannelMethods.pinContentWidget);

  Future<void> refreshContentWidget() =>
      invokeVoid(ChannelMethods.refreshContentWidget);

  /// Pushes bubble and/or home-widget appearance to native. Each arg is a style
  /// wire map (see `BubbleStyle.toWire` / `WidgetStyle.toWire`); only the keys
  /// present are updated. No-op off-Android.
  Future<void> setCounterStyle({
    Map<String, dynamic>? bubble,
    Map<String, dynamic>? widget,
  }) => invokeVoid(ChannelMethods.setCounterStyle, {
    'bubble': ?bubble,
    'widget': ?widget,
  });

  /// Package names of the device's user-launchable apps. Returns `null` when the
  /// native engine is unavailable (iOS / tests / channel error) — callers treat
  /// `null` as "install state unknown" and show the full blocklist.
  Future<Set<String>?> installedPackages() async {
    final res = await _invoke<List<dynamic>>(ChannelMethods.installedPackages);
    return res?.cast<String>().toSet();
  }

  /// The device's user-launchable apps with label and icon, or `null` when the
  /// native engine is unavailable (iOS / tests / channel error).
  ///
  /// Mapping happens inside the same null-on-error contract as [_invoke]: a
  /// drifted native payload (wrong-typed element) must degrade to "unknown",
  /// not leave callers waiting on a thrown future. Rows without a package name
  /// are dropped — they could never match an event package.
  Future<List<InstalledApp>?> installedApps() async {
    final res = await _invoke<List<dynamic>>(ChannelMethods.installedApps);
    if (res == null) return null;
    try {
      return res
          .map((e) => InstalledApp.fromChannel(e as Map))
          .where((a) => a.packageName.isNotEmpty)
          .toList();
    } on Object catch (e) {
      AppLogger.e('channel ${ChannelMethods.installedApps} bad payload', e);
      return null;
    }
  }

  /// Labels of installed browsers the web blocker cannot enforce in, or `null`
  /// when unknown (iOS / tests / channel error). Empty list means "every
  /// browser you have is covered" — a meaningfully different answer from
  /// `null`, so the two are not collapsed.
  Future<List<String>?> unsupportedBrowsers() async {
    final res = await _invoke<List<dynamic>>(
      ChannelMethods.unsupportedBrowsers,
    );
    if (res == null) return null;
    try {
      return res
          .map((e) => (e as Map)['label']?.toString() ?? '')
          .where((l) => l.isNotEmpty)
          .toList();
    } on Object catch (e) {
      AppLogger.e(
        'channel ${ChannelMethods.unsupportedBrowsers} bad payload',
        e,
      );
      return null;
    }
  }
}
