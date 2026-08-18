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
