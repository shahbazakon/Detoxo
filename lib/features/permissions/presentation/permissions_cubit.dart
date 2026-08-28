import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Drives the permission funnel: loads statuses, requests, and re-checks (e.g.
/// when the app resumes after the user returns from a system settings screen).
///
/// Also detects Android's restricted-settings (13/14) / Enhanced Confirmation
/// Mode (15+) gate, which silently refuses the Accessibility, overlay and
/// device-admin toggles for apps installed outside the Play Store. Android
/// exposes no way to ask whether the gate is active — the appop behind it is
/// `@hide`, read-restricted, and defaults to `MODE_DEFAULT` under ECM — so this
/// is inferred from behaviour: the grant was attempted, the user came back, and
/// nothing changed.
class PermissionsCubit extends Cubit<List<PermissionStatus>> {
  PermissionsCubit(this._repo) : super(const []);

  final PermissionRepository _repo;

  /// Attempts that returned with the permission still denied, per permission.
  final Map<AppPermission, int> _attempts = {};

  /// Cached for the session; the installer cannot change while we're running.
  bool? _outsidePlay;

  /// Granted on the last successful check — the gate's memory when a live
  /// read comes back [PermissionState.unknown] (flaky channel at cold start).
  Set<AppPermission> _lastKnownGranted = const {};

  /// One failed attempt is noise — users back out, get distracted, or tap Grant
  /// just to look. Two round-trips with no change is a stuck user.
  static const int _attemptsBeforeHelp = 2;

  /// Whether [status] looks blocked by the restricted-settings gate rather than
  /// simply not granted yet. An `unknown` reading (channel hiccup, not a
  /// refusal) must never be relabelled permanently denied.
  bool needsRestrictedFix(PermissionStatus status) =>
      (_outsidePlay ?? false) &&
      !status.granted &&
      status.state != PermissionState.unknown &&
      status.kind.restrictedWhenSideloaded &&
      (_attempts[status.kind] ?? 0) >= _attemptsBeforeHelp;

  Future<void> refresh() async {
    _outsidePlay ??= await _repo.installedOutsidePlay();
    final statuses = await _repo.statuses();
    _lastKnownGranted = await _repo.lastKnownGranted();
    for (final s in statuses) {
      // Self-heal: once it lands, forget the failed attempts.
      if (s.granted) _attempts.remove(s.kind);
    }
    emit([
      for (final s in statuses)
        needsRestrictedFix(s)
            ? s.copyWith(state: PermissionState.permanentlyDenied)
            : s,
    ]);
  }

  Future<void> request(AppPermission permission) async {
    _attempts.update(permission, (n) => n + 1, ifAbsent: () => 1);
    await _repo.request(permission);
    // Re-check shortly after; system dialogs/settings are async.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await refresh();
  }

  /// Opens Detoxo's system settings page so the user can lift the
  /// restricted-settings block. Clears the attempt counts so the cards read
  /// "Grant" again when they come back.
  Future<void> openAppSettings() async {
    _attempts.clear();
    await _repo.openAppSettings();
  }

  /// The gate's per-permission truth, shared with the UI so the cards, the
  /// progress row and the Continue button can never contradict each other:
  /// granted, or a live `unknown` reading backed by the last successful check.
  /// A definitive `denied` is false, regardless of history.
  bool effectivelyGranted(PermissionStatus s) =>
      s.granted ||
      (s.state == PermissionState.unknown &&
          _lastKnownGranted.contains(s.kind));

  /// Required-permissions gate. A live `unknown` reading falls back to the
  /// last successful check instead of reading as denied — one flaky channel
  /// call at cold start must not send a set-up user back to the setup wall.
  bool get allRequiredGranted =>
      state.where((s) => s.kind.required).every(effectivelyGranted);
}
