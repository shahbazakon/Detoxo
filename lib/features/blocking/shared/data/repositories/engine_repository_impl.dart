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

  @override
  Stream<ServiceSnapshot> statusStream() async* {
    yield await currentStatus();
    await for (final e in _channel.events()) {
      final type = e['type'] as String?;
      if (type == ChannelEvents.serviceStatus) {
        yield ServiceSnapshot(
          status: (e['running'] as bool? ?? false)
              ? ServiceStatus.running
              : ServiceStatus.stopped,
          blocksToday: _today,
          blocksTotal: _total,
        );
      } else if (type == ChannelEvents.blocked) {
        _today = e['today'] as int? ?? _today;
        _total = e['total'] as int? ?? _total;
        yield ServiceSnapshot(
          status: ServiceStatus.running,
          blocksToday: _today,
          blocksTotal: _total,
        );
      }
    }
  }

  @override
  Stream<BlockEvent> blockStream() async* {
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.blocked) continue;
      yield BlockEvent(
        platformId: e['platformId'] as String? ?? 'unknown',
        packageName: e['package'] as String? ?? '',
        mode: BlockingMode.fromWire(e['mode'] as String?),
        timestamp: DateTime.now(),
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
    final stats = await _channel.blockStats();
    _today = stats['today'] as int? ?? 0;
    _total = stats['total'] as int? ?? 0;
    return ServiceSnapshot(
      status: alive ? ServiceStatus.running : ServiceStatus.stopped,
      blocksToday: _today,
      blocksTotal: _total,
    );
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
    });
  }

  @override
  Future<void> pushWebBlocklist(String json) => _channel.pushWebBlocklist(json);

  @override
  Future<void> pushProtectedApps(List<String> packages) =>
      _channel.pushProtectedApps(packages);

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
}
