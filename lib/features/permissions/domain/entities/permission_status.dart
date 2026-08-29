import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// A single runtime permission's status in the onboarding funnel.
class PermissionStatus extends Equatable {
  const PermissionStatus({
    required this.kind,
    this.state = PermissionState.unknown,
  });

  final AppPermission kind;
  final PermissionState state;

  bool get granted => state == PermissionState.granted;

  /// OS won't prompt again — the only recovery is the app's system settings.
  bool get permanentlyDenied => state == PermissionState.permanentlyDenied;

  /// Android's restricted-settings / ECM gate is swallowing the grant, so the
  /// fix is the App-info walkthrough rather than another trip to the toggle.
  /// Notifications can also be [permanentlyDenied], but for the ordinary
  /// don't-ask-again reason — hence the [kind] check.
  bool get blockedByRestrictedSettings =>
      permanentlyDenied && kind.restrictedWhenSideloaded;

  PermissionStatus copyWith({PermissionState? state}) =>
      PermissionStatus(kind: kind, state: state ?? this.state);

  @override
  List<Object?> get props => [kind, state];
}

/// Runtime permissions the app guides the user through.
///
/// [why] lives here rather than in each screen because three surfaces render it
/// (the funnel, the settings sheet, the dashboard card) and the copies drifted.
enum AppPermission {
  accessibility(
    'Accessibility',
    'Lets Detoxo detect and block reels & shorts.',
    required: true,
  ),
  overlay(
    'Display over apps',
    'Shows the block / PIN screen over other apps.',
    required: true,
  ),
  notifications(
    'Notifications',
    'Alerts you if protection stops.',
    required: false,
  ),
  usageAccess('Usage access', 'Powers app usage limits.', required: false),
  batteryOptimization(
    'Unrestricted battery',
    'Keeps the blocker alive in the background.',
    required: false,
  ),
  deviceAdmin(
    'Uninstall protection',
    'Optional uninstall protection.',
    required: false,
  ),
  notificationListener(
    'Notification access',
    'Silences notifications from apps you have locked.',
    required: false,
  );

  const AppPermission(this.label, this.why, {required this.required});
  final String label;
  final String why;
  final bool required;

  /// Toggles Android's restricted-settings (13/14) / Enhanced Confirmation Mode
  /// (15+) gate can silently refuse when the installer isn't trusted.
  bool get restrictedWhenSideloaded =>
      this == accessibility ||
      this == overlay ||
      this == deviceAdmin ||
      this == notificationListener;
}
