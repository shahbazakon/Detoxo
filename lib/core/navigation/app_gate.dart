import 'package:detoxo/core/navigation/routes.dart';
import 'package:flutter/foundation.dart';

/// What the router is allowed to show, and in what order the gates apply.
///
/// The gate order used to be written in three places — the splash's imperative
/// `context.go` chain, the PIN screen's `onUnlocked`, and (by re-entering the
/// splash) the end of onboarding. [redirect] is now the only copy.
///
/// A plain [ChangeNotifier] rather than a read of the cubits: `GoRouter` wants a
/// `refreshListenable` and cubits are `Stream`s, so this is the least code that
/// bridges the two. It also keeps `navigation/` free of feature imports and
/// makes the order testable without a widget tree. The flags are pushed in by
/// `BlocListener`s in `main.dart`.
///
/// ponytail: a single flat gate order. A sixth gate, or one that depends on
/// another's outcome, is the point to extract a policy object.
class AppGate extends ChangeNotifier {
  /// Bootstrap has finished, so the other flags mean something. Until then the
  /// splash is the only legal screen — a redirect decided from unloaded state
  /// would flash the wrong destination on every cold start.
  bool get ready => _ready;
  bool _ready = false;

  /// This platform can actually block. False routes to [Routes.unsupported],
  /// which is what that constant was always for.
  bool get supported => _supported;
  bool _supported = true;

  bool get onboarded => _onboarded;
  bool _onboarded = false;

  /// The *launch* gate only, and therefore a session flag rather than a derived
  /// one: it is armed once by the bootstrap and cleared by a successful unlock.
  /// Re-locking on resume is `PinAutoRelock`'s job and does not route.
  bool get pinLocked => _pinLocked;
  bool _pinLocked = false;

  bool get permissionsOk => _permissionsOk;
  bool _permissionsOk = false;

  /// Screens that exist only to be passed through. Reaching one with every gate
  /// satisfied means the reason it was shown is gone, so the router moves on.
  ///
  /// [Routes.permissions] is deliberately NOT here: granting the two required
  /// permissions must not yank the user off the screen while they are still
  /// working through the recommended ones. They leave by its own Continue.
  static const Set<String> _passThrough = {
    Routes.splash,
    Routes.onboarding,
    Routes.pinLock,
    Routes.unsupported,
  };

  /// Where the permissions gate is allowed to interrupt: launch, and the home
  /// surface the user is idling on.
  ///
  /// It deliberately does NOT reach into a deeper screen. The gate used to be
  /// an imperative chain the splash ran once; as a global redirect it
  /// re-evaluates on every `PermissionsCubit` emit — and that cubit re-emits on
  /// every app resume. Losing accessibility while the user is composing a rule
  /// at `/rules/edit` would therefore destroy the editor, its unsaved rule and
  /// its `state.extra`, with no warning. The funnel is not so urgent that it is
  /// worth throwing away work: they get it on the next trip through home.
  static const Set<String> _permissionsGateApplies = {
    ..._passThrough,
    Routes.home,
    Routes.permissions,
  };

  /// The whole gating decision. Returns the path to redirect to, or null to
  /// stay put — including when [location] already IS the destination, which is
  /// what stops `GoRouter` looping.
  String? redirect(String location) {
    String? to(String route) => location == route ? null : route;

    if (!_ready) return to(Routes.splash);
    if (!_supported) return to(Routes.unsupported);
    if (!_onboarded) return to(Routes.onboarding);
    if (_pinLocked) return to(Routes.pinLock);
    if (!_permissionsOk && _permissionsGateApplies.contains(location)) {
      return to(Routes.permissions);
    }
    return _passThrough.contains(location) ? Routes.home : null;
  }

  /// Bulk update from the bootstrap and the app-wide listeners. Notifies once,
  /// and only when something actually moved — every notify re-runs the redirect
  /// for the whole stack.
  void update({
    bool? ready,
    bool? supported,
    bool? onboarded,
    bool? pinLocked,
    bool? permissionsOk,
  }) {
    final changed =
        (ready != null && ready != _ready) ||
        (supported != null && supported != _supported) ||
        (onboarded != null && onboarded != _onboarded) ||
        (pinLocked != null && pinLocked != _pinLocked) ||
        (permissionsOk != null && permissionsOk != _permissionsOk);
    if (!changed) return;
    _ready = ready ?? _ready;
    _supported = supported ?? _supported;
    _onboarded = onboarded ?? _onboarded;
    _pinLocked = pinLocked ?? _pinLocked;
    _permissionsOk = permissionsOk ?? _permissionsOk;
    notifyListeners();
  }

  /// A successful launch unlock. Separate from [update] because it is an event,
  /// not a state read — nothing recomputes `pinLocked` back to true.
  void unlockPin() => update(pinLocked: false);

  /// "Reset app data" re-enters the splash without restarting the process, so
  /// the gate has to go back to its cold-start state or the redirect would keep
  /// waving the user through on flags from before the wipe.
  void reset() {
    _ready = false;
    _onboarded = false;
    _pinLocked = false;
    _permissionsOk = false;
    notifyListeners();
  }
}
