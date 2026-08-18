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
  Stream<Map<String, dynamic>> events() {
    if (!PlatformCapabilities.supportsBlockingEngine) {
      return const Stream<Map<String, dynamic>>.empty();
    }
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((dynamic e) => Map<String, dynamic>.from(e as Map))
        .handleError((Object error) {
          AppLogger.e('engine event stream error', error);
        })
        .asBroadcastStream();
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

  Future<bool> invokeBool(String method, [Map<String, dynamic>? args]) async =>
      (await _invoke<bool>(method, args)) ?? false;

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

  Future<bool> hasUsageAccess() => invokeBool(ChannelMethods.hasUsageAccess);
  Future<void> openUsageAccess() =>
      invokeVoid(ChannelMethods.openUsageAccessSettings);

  Future<bool> isIgnoringBattery() =>
      invokeBool(ChannelMethods.isIgnoringBatteryOptimizations);
  Future<void> requestIgnoreBattery() =>
      invokeVoid(ChannelMethods.requestIgnoreBatteryOptimizations);

  Future<bool> isDeviceAdminActive() =>
      invokeBool(ChannelMethods.isDeviceAdminActive);
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

  Future<void> performBack() => invokeVoid(ChannelMethods.performBack);
  Future<void> killApp(String pkg) =>
      invokeVoid(ChannelMethods.killApp, {'package': pkg});
  Future<void> lockScreen() => invokeVoid(ChannelMethods.lockScreen);

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
}
