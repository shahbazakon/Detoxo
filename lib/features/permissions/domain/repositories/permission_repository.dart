import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';

/// Checks/requests the runtime permissions in the onboarding funnel.
abstract interface class PermissionRepository {
  Future<List<PermissionStatus>> statuses();
  Future<PermissionStatus> status(AppPermission permission);
  Future<void> request(AppPermission permission);

  /// Permissions that read as granted on the last successful check. The gate's
  /// fallback when a live read comes back `unknown` — one flaky channel call
  /// at cold start must not re-open the setup wall.
  Future<Set<AppPermission>> lastKnownGranted();

  /// True when Detoxo was not installed by the Play Store, so Android's
  /// restricted-settings / ECM gate can silently swallow the Accessibility,
  /// overlay and device-admin toggles. There is no API to query the gate
  /// itself, so the installer is the only signal available.
  Future<bool> installedOutsidePlay();

  /// Opens Detoxo's own system settings page — the screen whose ⋮ overflow
  /// holds "Allow restricted settings".
  Future<void> openAppSettings();
}
