// Real-boot end-to-end walk. Runs on an attached Android device:
//
//   bash tool/qa.sh -d <serial> e2e
//
// ONE `testWidgets` only. `app.main()` runs `configureDependencies()`, which
// calls `registerSingleton` with no `allowReassignment`, and nothing ever calls
// `sl.reset()` — a second booting test in this isolate dies with
// "Object/factory with type LocalStore is already registered".
//
// Never `pumpAndSettle`: GlassScaffold's ambient background repeats forever
// (core/design_system/foundations/ambient_background.dart), so it never
// converges. Use `settle` (fixed frames) and `waitFor` (polls real frames).
//
// The walk BRANCHES on whatever screen it lands on — the device may already be
// onboarded and holding real user data. It never assumes a fresh install and
// never taps "Reset app data".
//
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: always_use_package_imports — integration_test/ is outside lib/, so
// package: cannot reach it. See the header of qa_walk.dart.
import 'qa_walk.dart';

/// Opens the right-side app drawer.
///
/// DashboardTopBar — and therefore DrawerMenuButton — is the FIRST CHILD of the
/// dashboard ListView (dashboard_tab.dart), so the header scrolls away with the
/// content. The showcase tour scrolls the mode pills into view and leaves the
/// list offset, which parks the button above the viewport's clip: `find.byIcon`
/// still matches it, but `tap()` warns "would not hit test on the specified
/// widget" and the drawer never opens. Snap to the top first.
///
/// `jumpTo`, not a drag: overscrolling at the top fires the RefreshIndicator.
Future<void> openDrawer(WidgetTester tester) async {
  final position = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  if (position.pixels != 0) position.jumpTo(0);
  await settle(tester);
  await tester.tap(find.byIcon(Icons.menu_rounded));
  await settle(tester, frames: 12);
}

/// Ends a step: asserts nothing threw, then holds the screen long enough for
/// `tool/qa.sh` to grab a framebuffer when it sees the QA_SHOT marker.
Future<void> step(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  debugPrint('QA_STEP:$name');
  debugPrint('QA_SHOT:$name');
  await settle(tester, frames: 12);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots, clears every gate and survives a theme flip', (
    tester,
  ) async {
    await bootApp();
    await settle(tester, frames: 10);
    await step(tester, 'splash');

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
      await step(tester, 'onboarding');
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
      await step(tester, 'permissions');
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
    await step(tester, 'home');

    // The 7-step tour auto-starts on the first /home when hasSeenFeatureShowcase
    // is false, with disableBarrierInteraction + disableDefaultTargetGestures —
    // it swallows every dashboard tap until Skip. Absent on an already-toured
    // device, hence conditional.
    final skip = find.text('Skip');
    if (await waitFor(tester, skip, timeout: const Duration(seconds: 10))) {
      await step(tester, 'showcase');
      await tester.tap(skip);
      await settle(tester, frames: 14);
      expect(skip, findsNothing, reason: 'showcase tour was not dismissed');
    }

    // Real state assertions — the walk persisted to Hive, it did not merely
    // paint the right pixels.
    final settings = BlocProvider.of<SettingsCubit>(tester.element(home.first));
    expect(settings.state.onboarded, isTrue, reason: 'onboarded not persisted');
    expect(
      settings.state.hasSeenFeatureShowcase,
      isTrue,
      reason: 'showcase-seen not persisted',
    );

    // Drawer -> Appearance -> flip the theme, capturing both.
    await openDrawer(tester);
    expect(
      await waitFor(tester, find.text('Appearance')),
      isTrue,
      reason: 'drawer did not open',
    );
    await step(tester, 'drawer');

    await tester.tap(find.text('Appearance'));
    await settle(tester, frames: 12);
    // 'THEME', not 'Theme': SectionHeader renders `label.toUpperCase()`
    // (core/widgets/common_widgets.dart). find.text matches the rendered string,
    // so every section header in this app is screamed. GlassSegmented and
    // GhostButton pass their labels through verbatim.
    expect(
      await waitFor(tester, find.text('THEME')),
      isTrue,
      reason: 'Appearance screen did not open',
    );

    await tester.tap(find.text('Light'));
    await settle(tester, frames: 14);
    expect(settings.state.themeMode, AppThemeMode.light);
    await step(tester, 'appearance-light');

    await tester.tap(find.text('Dark'));
    await settle(tester, frames: 14);
    expect(settings.state.themeMode, AppThemeMode.dark);
    await step(tester, 'appearance-dark');

    await tester.pageBack();
    await settle(tester, frames: 12);
    expect(await waitFor(tester, home), isTrue, reason: 'no way back to /home');

    // Two more screens, read-only. Never tap 'Reset app data'.
    await openDrawer(tester);
    await tester.tap(find.text('Settings'));
    await settle(tester, frames: 14);
    // 'PROTECTION' (uppercased SectionHeader) is the marker, not the more
    // obvious 'Reset app data': that GhostButton sits at the BOTTOM of a lazy
    // ListView, so it is never built into the element tree and find.text cannot
    // see it without scrolling there — which this walk deliberately will not do.
    expect(
      await waitFor(tester, find.text('PROTECTION')),
      isTrue,
      reason: 'Settings screen did not open',
    );
    await step(tester, 'settings');

    await tester.pageBack();
    await settle(tester, frames: 12);

    await openDrawer(tester);
    await tester.tap(find.text('Activity'));
    await settle(tester, frames: 16);
    // Prove we navigated rather than screenshotting a stale dashboard: the home
    // marker is gone, and the one surviving 'Activity' is the GlassAppBar title
    // (the drawer item that shared the string went with the drawer).
    expect(home, findsNothing, reason: 'still on the dashboard');
    expect(find.text('Activity'), findsOneWidget);
    await step(tester, 'analytics');

    await tester.pageBack();
    await settle(tester, frames: 12);
    expect(await waitFor(tester, home), isTrue);
    await step(tester, 'home-final');

    expect(tester.takeException(), isNull, reason: 'end of walk');
  });
}
