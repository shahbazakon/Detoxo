import 'dart:async';
import 'dart:convert';

import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Resolves permission status via the native channel (accessibility, overlay,
/// usage, battery, device-admin) and permission_handler (notifications).
///
/// Reads are tri-state: a channel call that doesn't answer reads as
/// [PermissionState.unknown] (after one retry), never as denied — and every
/// successful check persists the granted set so the splash gate has a memory
/// to fall back on. Without this, one flaky read at cold start re-opened the
/// full permission setup wall for an already-set-up user.
class PermissionRepositoryImpl implements PermissionRepository {
  PermissionRepositoryImpl(this._channel, this._store);

  final EngineChannel _channel;
  final LocalStore _store;

  @override
  Future<List<PermissionStatus>> statuses() async {
    // The Android permission funnel has no iOS equivalent. Returning an empty
    // list makes PermissionsCubit.allRequiredGranted vacuously true, so the
    // splash gate routes straight to /home on iOS.
    if (!PlatformCapabilities.usesAndroidPermissionFunnel) return const [];
    // Concurrent, not serial: each leg is an independent channel round trip
    // that retries once after 150 ms on a null read, and this runs inside the
    // splash gate's Future.wait. Serially that was N round trips plus up to
    // N x 150 ms of retry delay on the cold-start critical path.
    final result = await Future.wait(AppPermission.values.map(status));
    _persistGranted(result);
    return result;
  }

  @override
  Future<PermissionStatus> status(AppPermission permission) async {
    if (!PlatformCapabilities.usesAndroidPermissionFunnel) {
      return PermissionStatus(kind: permission, state: PermissionState.denied);
    }
    // Notifications is the one true runtime permission: it can be
    // permanently denied (don't-ask-again), which the settings-based ones can't.
    if (permission == AppPermission.notifications) {
      try {
        final s = await ph.Permission.notification.status;
        return PermissionStatus(
          kind: permission,
          state: s.isGranted
              ? PermissionState.granted
              : s.isPermanentlyDenied
              ? PermissionState.permanentlyDenied
              : PermissionState.denied,
        );
      } on Object catch (e) {
        // A plugin throw must read as "unknown" — an uncaught rejection here
        // used to fail the splash's Future.wait and hang the app on the splash.
        AppLogger.e('notification permission status failed', e);
        return PermissionStatus(kind: permission); // state defaults to unknown
      }
    }
    var granted = await _read(permission);
    if (granted == null) {
      // One flaky channel read must not read as "denied". Retry once, then
      // admit "unknown" and let the gate fall back to [lastKnownGranted].
      await Future<void>.delayed(const Duration(milliseconds: 150));
      granted = await _read(permission);
    }
    return PermissionStatus(
      kind: permission,
      state: switch (granted) {
        true => PermissionState.granted,
        false => PermissionState.denied,
        null => PermissionState.unknown,
      },
    );
  }

  Future<bool?> _read(AppPermission permission) => switch (permission) {
    AppPermission.accessibility => _channel.invokeBoolOrNull(
      ChannelMethods.isAccessibilityEnabled,
    ),
    AppPermission.overlay => _channel.invokeBoolOrNull(
      ChannelMethods.canDrawOverlays,
    ),
    AppPermission.usageAccess => _channel.invokeBoolOrNull(
      ChannelMethods.hasUsageAccess,
    ),
    AppPermission.batteryOptimization => _channel.invokeBoolOrNull(
      ChannelMethods.isIgnoringBatteryOptimizations,
    ),
    AppPermission.deviceAdmin => _channel.invokeBoolOrNull(
      ChannelMethods.isDeviceAdminActive,
    ),
    AppPermission.notificationListener => _channel.invokeBoolOrNull(
      ChannelMethods.isNotificationListenerEnabled,
    ),
    AppPermission.notifications => Future.value(false), // handled in status()
  };

  @override
  Future<Set<AppPermission>> lastKnownGranted() async {
    final byName = AppPermission.values.asNameMap();
    return {for (final n in _readGrantedNames()) ?byName[n]};
  }

  /// Updates the persisted granted set: adds every granted, removes every
  /// definitively denied, leaves unknown untouched. Fire-and-forget.
  void _persistGranted(List<PermissionStatus> statuses) {
    final known = <String>{..._readGrantedNames()};
    var changed = false;
    for (final s in statuses) {
      if (s.state == PermissionState.granted) {
        changed = known.add(s.kind.name) || changed;
      } else if (s.state != PermissionState.unknown) {
        changed = known.remove(s.kind.name) || changed;
      }
    }
    if (changed) {
      // Guarded: an IO failure (disk full) must log, not surface as an
      // uncaught-zone error — and losing the write only means the granted-set
      // memory stays one refresh stale.
      unawaited(
        _store
            .write(StoreKeys.grantedPermissions, jsonEncode(known.toList()))
            .catchError(
              (Object e) => AppLogger.e('granted-set persist failed', e),
            ),
      );
    }
  }

  List<String> _readGrantedNames() {
    final raw = _store.read(StoreKeys.grantedPermissions);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } on Object {
      return const []; // corrupt blob: no memory beats a crash
    }
  }

  @override
  Future<void> request(AppPermission permission) async {
    if (!PlatformCapabilities.usesAndroidPermissionFunnel) return;
    switch (permission) {
      case AppPermission.accessibility:
        await _channel.openAccessibilitySettings();
      case AppPermission.overlay:
        await _channel.requestOverlay();
      case AppPermission.usageAccess:
        await _channel.openUsageAccess();
      case AppPermission.batteryOptimization:
        await _channel.requestIgnoreBattery();
      case AppPermission.deviceAdmin:
        await _channel.requestDeviceAdmin();
      case AppPermission.notificationListener:
        // No programmatic grant exists: the user toggles Detoxo on in the
        // system's "Notification access" list themselves.
        await _channel.openNotificationListenerSettings();
      case AppPermission.notifications:
        // A plain request() no-ops once permanently denied — send the user to
        // the app's settings screen instead so they have a recovery path.
        if (await ph.Permission.notification.isPermanentlyDenied) {
          await ph.openAppSettings();
        } else {
          await ph.Permission.notification.request();
        }
    }
  }

  @override
  Future<bool> installedOutsidePlay() async {
    if (!PlatformCapabilities.usesAndroidPermissionFunnel) return false;
    try {
      // package_info_plus reads getInstallSourceInfo().initiatingPackageName on
      // API 30+, which — unlike the installing package — cannot be rewritten
      // after install. Play is the only installer exempt from the gate in
      // practice; an adb/debug install reports null, which is also restricted.
      final store = (await PackageInfo.fromPlatform()).installerStore;
      return store != _playStorePackage;
    } catch (_) {
      // Unknown installer: don't guess, don't nag.
      return false;
    }
  }

  @override
  Future<void> openAppSettings() => ph.openAppSettings();

  static const String _playStorePackage = 'com.android.vending';
}
