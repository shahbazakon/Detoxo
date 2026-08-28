// Shared plumbing for the real-boot integration tests (app_e2e_test.dart and
// app_perf_test.dart). Driven by `tool/qa.sh`; see
// .claude/skills/detoxo-auto-test/SKILL.md.
//
// This lives outside lib/, so the only way to reach it is a relative import and
// `always_use_package_imports` (analysis_options.yaml) forbids that without an
// ignore. Two ignore comments beat two divergent copies of `bootApp` — the
// Crashlytics handler dance below is subtle and silently breaks a run when it
// drifts.

import 'dart:ui' show PlatformDispatcher;

import 'package:detoxo/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed-frame settle — the repo-wide substitute for `pumpAndSettle`.
///
/// `pumpAndSettle` never returns here: GlassScaffold's ambient background
/// repeats forever (core/design_system/foundations/ambient_background.dart), so
/// the frame queue never drains.
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Pumps real frames until [finder] matches or [timeout] elapses.
Future<bool> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(const Duration(milliseconds: 120));
  }
  return finder.evaluate().isNotEmpty;
}

/// Pumps real frames until [finder] matches nothing or [timeout] elapses.
Future<bool> waitForGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) return true;
    await tester.pump(const Duration(milliseconds: 120));
  }
  return finder.evaluate().isEmpty;
}

/// Index of the first finder in [finders] to appear, or -1 if none does.
Future<int> waitForAny(
  WidgetTester tester,
  List<Finder> finders, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (var i = 0; i < finders.length; i++) {
      if (finders[i].evaluate().isNotEmpty) return i;
    }
    await tester.pump(const Duration(milliseconds: 120));
  }
  return -1;
}

/// Boots the real app the way `main()` does, then undoes the one thing `main()`
/// does that the test harness cannot survive.
///
/// `FirebaseCrashReportingService.installGlobalHandlers()` replaces BOTH
/// `FlutterError.onError` and `PlatformDispatcher.instance.onError` with
/// Crashlytics handlers. That swallows flutter_test's error plumbing and the run
/// dies on "A test overrode FlutterError.onError but either failed to return it
/// to its original state..." — which masks whatever actually went wrong. Capture
/// both before the boot and put them back after.
Future<void> bootApp() async {
  final onError = FlutterError.onError;
  final platformOnError = PlatformDispatcher.instance.onError;
  await app.main();
  FlutterError.onError = onError;
  PlatformDispatcher.instance.onError = platformOnError;
}

/// Screen markers. No screen in this app has a test key, so every handle is a
/// proven text string. Note `find.text` matches the RENDERED string:
/// `SectionHeader` uppercases (`'THEME'`, not `'Theme'`), and the bottom nav
/// pill carries `Semantics(label:)` only — `find.text('Dashboard')` finds
/// nothing, the real dashboard marker is `'Block All'`.
const kOnboardingMarker = 'Take your time back';
const kPermissionsMarker = 'Set up protection';
const kPinLockMarker = 'Enter your PIN';
const kHomeMarker = 'Block All';

/// Ends a step: asserts nothing threw, then holds the screen long enough for
/// `tool/qa.sh` to grab a framebuffer when it sees the QA_SHOT marker.
Future<void> step(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  debugPrint('QA_STEP:$name');
  debugPrint('QA_SHOT:$name');
  await settle(tester, frames: 12);
}

/// Walks a freshly booted app to the dashboard, branching on whatever screen
/// the splash lands on (fresh install → onboarding; a phone holding real data →
/// straight to home), then dismisses the first-run showcase tour. Calls [step]
/// at each screen so the caller can screenshot. Fails loudly on an app-scope
/// PIN — no walk can type one. Returns the dashboard marker finder.
Future<Finder> reachHome(
  WidgetTester tester, {
  required Future<void> Function(String name) step,
}) async {
  final onboarding = find.text(kOnboardingMarker);
  final permissions = find.text(kPermissionsMarker);
  final pinLock = find.text(kPinLockMarker);
  final home = find.text(kHomeMarker);

  // SplashScreen._bootstrap awaits settings/permissions/pin, then on first run
  // targets.load() — a native config push plus a full installed-package scan.
  // 90s is deliberate; a cold phone with hundreds of apps is slow.
  final landed = await waitForAny(tester, [
    onboarding,
    permissions,
    pinLock,
    home,
  ]);
  expect(landed, isNot(-1), reason: 'splash never routed anywhere');

  if (landed == 2) {
    fail(
      'this device has an app-scope PIN set and the walk cannot type it. '
      'Clear app data first: bash tool/qa.sh -d <serial> --reset prep',
    );
  }

  if (landed == 0) {
    await step('onboarding');
    await tester.tap(find.text('Skip'));
    // Two hops, not one: _finish persists `onboarded`, seeds the daily limit,
    // then bounces through the SPLASH so SettingsCubit re-bootstraps from the
    // flag it just wrote (see onboarding_screen.dart) — the splash gate is
    // what finally lands on /permissions. A fixed settle races that.
    expect(
      await waitForAny(tester, [
        permissions,
        home,
      ], timeout: const Duration(seconds: 45)),
      isNot(-1),
      reason: 'Skip did not leave onboarding',
    );
  }

  // Required permissions are accessibility + overlay, and there is NO skip:
  // the CTA is `onPressed: allRequired ? … : null`. tool/qa.sh pre-granted
  // both over adb, so the label must have flipped to 'Continue'.
  if (await waitFor(
    tester,
    permissions,
    timeout: const Duration(seconds: 20),
  )) {
    await step('permissions');
    final cont = find.text('Continue');
    expect(
      await waitFor(tester, cont, timeout: const Duration(seconds: 20)),
      isTrue,
      reason:
          'still showing "Grant required permissions" — accessibility and/or '
          'overlay did not stick. Run: bash tool/qa.sh -d <serial> prep',
    );
    await tester.tap(cont);
    await settle(tester, frames: 10);
  }

  expect(
    await waitFor(tester, home, timeout: const Duration(seconds: 45)),
    isTrue,
    reason: 'never reached the dashboard',
  );
  await step('home');

  // The 7-step tour auto-starts on the first /home when hasSeenFeatureShowcase
  // is false, with disableBarrierInteraction + disableDefaultTargetGestures —
  // it swallows every dashboard tap until Skip. Absent on an already-toured
  // device, hence conditional.
  final skip = find.text('Skip');
  if (await waitFor(tester, skip, timeout: const Duration(seconds: 10))) {
    await step('showcase');
    await tester.tap(skip);
    await settle(tester, frames: 14);
    expect(skip, findsNothing, reason: 'showcase tour was not dismissed');
  }
  return home;
}
