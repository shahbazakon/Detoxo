import 'dart:async';

import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/conscious_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/reel_session_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/session_defaults.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';

/// Bridges the native engine to the domain. Translates raw channel maps into
/// typed [ServiceSnapshot] / [BlockEvent] streams and pushes config/settings.
class EngineRepositoryImpl implements EngineRepository {
  EngineRepositoryImpl(this._channel);

  final EngineChannel _channel;

  int _today = 0;
  int _total = 0;
  int _yesterday = 0;
  Map<String, int> _byPackage = const {};

  @override
  Stream<ServiceSnapshot> statusStream() async* {
    yield await currentStatus();
    await for (final e in _channel.events()) {
      final type = e['type'] as String?;
      if (type == ChannelEvents.serviceStatus) {
        yield _snapshot(
          (e['running'] as bool? ?? false)
              ? ServiceStatus.running
              : ServiceStatus.stopped,
        );
      } else if (type == ChannelEvents.blocked) {
        _readCounts(e);
        yield _snapshot(ServiceStatus.running);
      }
    }
  }

  /// The counters as the last event or status query left them. Read with
  /// `as num?`, never `as int?`: a throwing cast inside this `async*` would
  /// end the subscription and freeze every tile for the process lifetime.
  void _readCounts(Map<String, dynamic> m) {
    _today = (m['today'] as num?)?.toInt() ?? _today;
    _total = (m['total'] as num?)?.toInt() ?? _total;
    _yesterday = (m['yesterday'] as num?)?.toInt() ?? _yesterday;
    final by = m['byPackage'];
    if (by is Map) {
      _byPackage = {
        for (final e in by.entries)
          if (e.key is String && e.value is num)
            e.key as String: (e.value as num).toInt(),
      };
    }
  }

  ServiceSnapshot _snapshot(ServiceStatus status) => ServiceSnapshot(
    status: status,
    blocksToday: _today,
    blocksTotal: _total,
    blocksYesterday: _yesterday,
    blocksByPackage: _byPackage,
  );

  @override
  Stream<BlockEvent> blockStream() async* {
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.blocked) continue;
      yield BlockEvent(
        platformId: e['platformId'] as String? ?? 'unknown',
        packageName: e['package'] as String? ?? '',
        mode: BlockingMode.fromWire(e['mode'] as String?),
        timestamp: DateTime.now(),
        wall: e['wall'] as bool? ?? false,
      );
    }
  }

  @override
  Stream<ConsciousState> consciousStream() async* {
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.consciousState) continue;
      yield ConsciousState.fromMap(e);
    }
  }

  @override
  Future<ConsciousState> consciousCurrent() async {
    final map = await _channel.consciousState();
    return map.isEmpty ? const ConsciousState() : ConsciousState.fromMap(map);
  }

  @override
  Stream<ReelSessionState> reelSessionStream() async* {
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.reelSessionState) continue;
      yield ReelSessionState.fromMap(e);
    }
  }

  @override
  Future<void> resetConsciousBank() => _channel.resetConsciousBank();

  @override
  Future<void> armReelSession(int count) => _channel.armReelSession(count);

  @override
  Future<ReelSessionState> reelSessionCurrent() async {
    final map = await _channel.reelSessionState();
    return map.isEmpty
        ? const ReelSessionState()
        : ReelSessionState.fromMap(map);
  }

  @override
  Future<ServiceSnapshot> currentStatus() async {
    final enabled = await _channel.isAccessibilityEnabled();
    // EVO-013: "running" needs the service INSTANCE alive, not just the
    // setting — some OEMs (ColorOS force-stop) kill the service while the
    // Settings.Secure string keeps listing it, and never rebind it.
    final alive = enabled && await _channel.serviceAlive();
    _readCounts(await _channel.blockStats());
    return _snapshot(alive ? ServiceStatus.running : ServiceStatus.stopped);
  }

  @override
  Future<void> pushConfig(String configJson) => _channel.pushConfig(configJson);

  @override
  Future<void> pushSettings(AppSettings settings) {
    // Push the *derived* enforcement state so Pause works over the existing
    // channel: native suspends all blocking during the pause window
    // (nativePauseUntil) and enforces the plan after. Conscious is enforced
    // natively as a token bucket — Dart only ships its tuning constants.
    final now = DateTime.now();
    return _channel.pushSettings({
      'activePlan': settings.effectiveNativePlan(now).wire,
      'defaultBlockMode': settings.defaultBlockMode.wire,
      'enabledPlatforms': settings.enabledPlatformIds.toList(),
      'vibration': settings.vibrationEnabled,
      'masterEnabled': settings.masterEnabled,
      'pauseUntil': settings.nativePauseUntil(now)?.millisecondsSinceEpoch ?? 0,
      'reelAllowance': settings.reelAllowance,
      'consciousEarnDivisor': SessionDefaults.consciousEarnDivisor,
      'consciousMaxBankMs': SessionDefaults.consciousMaxBank.inMilliseconds,
      'blockAdultWebsites': settings.blockAdultWebsites,
      'blockWebsitesForBlockedApps': settings.blockWebsitesForBlockedApps,
      'suppressNotifications': settings.suppressNotifications,
    });
  }

  @override
  Future<void> pushWebBlocklist(String json) => _channel.pushWebBlocklist(json);

  @override
  Future<void> pushProtectedApps(List<String> packages) =>
      _channel.pushProtectedApps(packages);

  @override
  Future<void> pushAppBlocklist(List<String> packages) =>
      _channel.pushAppBlocklist(packages);

  @override
  Future<void> pushNudgeConfig(AppSettings settings, List<String> packages) =>
      _channel.pushNudgeConfig(
        enabled: settings.nudgeEnabled,
        packages: packages,
        thresholdStepMs: settings.nudgeThresholdMinutes * 60 * 1000,
        dailyCap: settings.nudgeDailyCap,
      );

  @override
  Future<bool> pushRules(String? json, int nextBoundaryMs) =>
      _channel.pushRules(json, nextBoundaryMs);

  @override
  Stream<int> ruleBoundaryStream() async* {
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.ruleBoundary) continue;
      yield (e['atMs'] as num?)?.toInt() ?? 0;
    }
  }

  @override
  Future<void> pushTemporaryUnblocks(String json) =>
      _channel.pushTemporaryUnblocks(json);

  @override
  Future<String?> takePendingUnblock() => _channel.takePendingUnblock();

  @override
  Future<String?> takeNativeGrants() => _channel.takeNativeGrants();

  @override
  Future<void> performBack() => _channel.performBack();

  @override
  Future<void> killApp(String packageName) => _channel.killApp(packageName);

  @override
  Future<void> lockScreen() => _channel.lockScreen();

  @override
  Future<Set<String>?> installedPackages() => _channel.installedPackages();

  // lazySingleton => process-lifetime cache; the picker never rescans unless
  // asked. Never caches a null (transient) failure — stale beats nothing.
  // Concurrent misses share one in-flight scan (the native walk is seconds,
  // not millis, on busy devices — a double-open must not run it twice).
  List<InstalledApp>? _installedApps;
  Future<List<InstalledApp>?>? _installedAppsInFlight;

  @override
  Future<List<InstalledApp>?> installedApps({bool refresh = false}) {
    if (!refresh && _installedApps != null) {
      return Future.value(_installedApps);
    }
    return _installedAppsInFlight ??= () async {
      try {
        final apps = await _channel.installedApps();
        if (apps == null) return _installedApps;
        apps.sort(
          (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
        );
        return _installedApps = apps;
      } finally {
        _installedAppsInFlight = null;
      }
    }();
  }

  /// Not cached: the user can install or uninstall a browser between visits,
  /// and this runs once per screen open, not on the hot path.
  @override
  Future<List<String>?> unsupportedBrowsers() => _channel.unsupportedBrowsers();
}
