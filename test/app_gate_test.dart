import 'package:detoxo/core/navigation/app_gate.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppGate gate;

  /// Every gate satisfied — the state the app spends its life in.
  void openEverything() => gate.update(
    ready: true,
    supported: true,
    onboarded: true,
    pinLocked: false,
    permissionsOk: true,
  );

  setUp(() => gate = AppGate());

  group('gate order', () {
    test('nothing routes until the bootstrap says it is ready', () {
      // A redirect decided from unloaded state would flash the wrong screen on
      // every cold start.
      expect(gate.redirect(Routes.home), Routes.splash);
      expect(gate.redirect(Routes.onboarding), Routes.splash);
      expect(gate.redirect(Routes.splash), isNull, reason: 'already there');
    });

    test('each gate, in order, claims the redirect', () {
      final expected = <void Function(), String>{
        () => gate.update(supported: false): Routes.unsupported,
        () => gate.update(onboarded: false): Routes.onboarding,
        () => gate.update(pinLocked: true): Routes.pinLock,
        () => gate.update(permissionsOk: false): Routes.permissions,
      };
      for (final entry in expected.entries) {
        gate = AppGate();
        openEverything();
        entry.key();
        expect(gate.redirect(Routes.home), entry.value);
      }
    });

    test('an earlier gate wins over a later one', () {
      openEverything();
      gate.update(onboarded: false, pinLocked: true, permissionsOk: false);
      expect(gate.redirect(Routes.home), Routes.onboarding);
    });

    test('a gate never redirects to the screen already showing', () {
      // The loop guard. Returning the current location would make GoRouter
      // redirect forever.
      openEverything();
      gate.update(onboarded: false);
      expect(gate.redirect(Routes.onboarding), isNull);
      gate
        ..update(onboarded: true)
        ..update(pinLocked: true);
      expect(gate.redirect(Routes.pinLock), isNull);
    });
  });

  group('pass-through', () {
    test('a satisfied gate screen ejects to home', () {
      openEverything();
      for (final gateScreen in [
        Routes.splash,
        Routes.onboarding,
        Routes.pinLock,
        Routes.unsupported,
      ]) {
        expect(gate.redirect(gateScreen), Routes.home, reason: gateScreen);
      }
    });

    test('the permissions screen is NOT ejected once required are granted', () {
      // It is a destination, not just a gate: granting accessibility and
      // overlay must not yank the user off it while they are still working
      // through the recommended permissions. Its own Continue button leaves.
      openEverything();
      expect(gate.redirect(Routes.permissions), isNull);
    });

    test('ordinary screens are left alone', () {
      openEverything();
      for (final route in [Routes.home, Routes.settings, Routes.rules]) {
        expect(gate.redirect(route), isNull, reason: route);
      }
    });
  });

  group('notification', () {
    test('a real change notifies exactly once', () {
      var notified = 0;
      gate
        ..addListener(() => notified++)
        ..update(ready: true, onboarded: true);
      expect(notified, 1, reason: 'one notify for the whole update');
    });

    test('a no-op update does not notify', () {
      // Every notify re-runs the redirect for the whole stack. The permissions
      // cubit re-emits on EVERY resume, so this is the hot path.
      openEverything();
      var notified = 0;
      gate
        ..addListener(() => notified++)
        ..update(permissionsOk: true, onboarded: true);
      expect(notified, 0);
    });
  });

  group('session flags', () {
    test('unlocking the PIN hands over to the next gate, not to home', () {
      openEverything();
      gate
        ..update(pinLocked: true, permissionsOk: false)
        ..unlockPin();
      expect(gate.redirect(Routes.pinLock), Routes.permissions);
    });

    test('reset re-closes the gate for an in-process data wipe', () {
      // "Reset app data" re-enters the splash WITHOUT restarting the process.
      // Without this the redirect would wave the user straight back to home on
      // pre-wipe flags, and the bootstrap would never run.
      openEverything();
      gate.reset();
      expect(gate.ready, isFalse);
      expect(gate.redirect(Routes.splash), isNull);
      expect(gate.redirect(Routes.home), Routes.splash);
    });

    test('reset keeps platform support, which a wipe cannot change', () {
      openEverything();
      gate.reset();
      expect(gate.supported, isTrue);
    });
  });
}
