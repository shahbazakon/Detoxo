// Frame-timeline capture. PROFILE ONLY, and `flutter drive` only:
//
//   flutter drive --profile --no-pub -d <serial> \
//     --driver test_driver/perf_driver.dart \
//     --target integration_test/app_perf_test.dart
//
// `flutter test` cannot run this usefully: the timeline lands in
// `binding.reportData`, which is readable only through `driver.requestData`.
//
// This test assumes NOTHING about app state. `flutter test -d` uninstalls the
// app when the e2e walk finishes, and `tool/qa.sh perf` then `adb install -r`s a
// fresh profile APK — so by the time this runs the app has no Hive data, and it
// has to clear onboarding + permissions itself before there is a dashboard to
// scroll. (tool/qa.sh grants the permissions over adb and re-asserts the
// accessibility service on a loop, because every install revokes it.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: always_use_package_imports — integration_test/ is outside lib/, so
// package: cannot reach it. See the header of qa_walk.dart.
import 'qa_walk.dart';

void main() {
  // fullyLive: draw every frame the scheduler asks for. Under the default
  // policy the binding skips frames it was not explicitly asked to pump, and
  // the timeline comes back sparse and flatteringly fast.
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('dashboard scroll frame timeline', (tester) async {
    await bootApp();
    await settle(tester, frames: 10);

    final home = find.text(kHomeMarker);

    // Clear whatever gate this install landed on. Best-effort by design: the
    // e2e walk is what ASSERTS these screens behave: here they are only in the
    // way of the measurement.
    final landed = await waitForAny(tester, [
      find.text(kOnboardingMarker),
      find.text(kPermissionsMarker),
      home,
    ]);
    if (landed == 0) {
      await tester.tap(find.text('Skip'));
      await settle(tester, frames: 10);
    }
    final cont = find.text('Continue');
    if (await waitFor(tester, cont, timeout: const Duration(seconds: 20))) {
      await tester.tap(cont);
      await settle(tester, frames: 10);
    }

    expect(await waitFor(tester, home), isTrue, reason: 'never reached /home');

    // The one-time tour covers the dashboard and swallows gestures until Skip.
    final skip = find.text('Skip');
    if (await waitFor(tester, skip, timeout: const Duration(seconds: 10))) {
      await tester.tap(skip);
      await settle(tester, frames: 14);
    }

    // Let entrance animations finish so they do not dominate the sample.
    await settle(tester, frames: 25);

    // The dashboard ListView. ModeSelector's horizontal SingleChildScrollView is
    // nested below it, so `.first` is the vertical list we mean to fling.
    final list = find.byType(Scrollable).first;
    await binding.traceAction(() async {
      for (var i = 0; i < 5; i++) {
        await tester.fling(list, const Offset(0, -320), 2000);
        await settle(tester, frames: 14);
        await tester.fling(list, const Offset(0, 320), 2000);
        await settle(tester, frames: 14);
      }
    }, reportKey: 'dashboard_scroll');

    expect(tester.takeException(), isNull);
  });
}
