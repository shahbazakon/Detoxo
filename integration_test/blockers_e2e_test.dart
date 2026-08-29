// Real-device App Blocker + Web Blocker walk. Driven by `bash tool/qa.sh
// blockers`; see .claude/skills/detoxo-auto-test/SKILL.md.
//
// ONE `testWidgets` only (see app_e2e_test.dart for why). The walk drives the
// two blocker screens the way a user does — add YouTube as a custom whole-app
// block, add example.com to the website blocklist, pause it — and at each
// `QA_PROBE:<name>` marker hands the phone to the driver, which launches the
// target app / browser URL, watches `logcat -s DetoxoService:I` for the
// engine's block line and brings Detoxo back to the foreground. While the
// probe runs the test only sleeps: a backgrounded app renders no frames, so a
// pump there would hang until the driver re-foregrounds us.
//
// Needs com.google.android.youtube and com.android.chrome installed (the
// driver checks). Everything it adds is removed again before it ends.

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: always_use_package_imports
import 'qa_walk.dart';

/// Longer than the driver's slowest probe (20s watch + launch + re-foreground).
const kProbeHold = Duration(seconds: 40);

const kYouTube = 'com.google.android.youtube';
const kSite = 'example.com';

/// Prints the probe marker and sleeps (no pumping) until the driver has run the
/// probe and brought Detoxo back; then pumps the first post-resume frame.
Future<void> probe(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: 'before probe $name');
  debugPrint('QA_PROBE:$name');
  await Future<void>.delayed(kProbeHold);
  await tester.pump();
  await settle(tester, frames: 8);
}

/// Opens a dashboard blocker tile by its title. The tiles are the last
/// dashboard children — scroll them into view first.
Future<void> openTile(WidgetTester tester, String title) async {
  final tile = find.text(title);
  await tester.scrollUntilVisible(
    tile,
    150,
    scrollable: find.byType(Scrollable).first,
  );
  await settle(tester);
  await tester.tap(tile);
  await settle(tester, frames: 10);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('blocks a custom app and a website end to end', (tester) async {
    await bootApp();
    await settle(tester, frames: 10);
    final home = await reachHome(tester, step: (n) => step(tester, n));

    // ── App Blocker: add YouTube via the installed-app picker ───────────────
    await openTile(tester, 'App Blocker');
    expect(
      await waitFor(tester, find.text('Block apps')),
      isTrue,
      reason: 'App Blocker screen did not open',
    );
    await step(tester, 'app-blocker');

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Add app'));
    await settle(tester, frames: 8);
    // The picker's search field is the last TextField in the tree (the screen
    // behind it may carry its own). Filtering first keeps the YouTube tile
    // inside the lazy list's viewport; the package subtitle is the unique
    // handle (the curated section behind the sheet also renders "YouTube").
    await tester.enterText(find.byType(TextField).last, 'youtube');
    final ytTile = find.text(kYouTube);
    expect(
      await waitFor(tester, ytTile, timeout: const Duration(seconds: 60)),
      isTrue,
      reason: 'YouTube not listed in the picker (installed-app scan failed?)',
    );
    await tester.tap(ytTile);
    await settle(tester);
    await tester.tap(find.text('Block (1)'));
    // Sheet pops, cubit.add commits, the row lands in "Custom apps".
    expect(
      await waitFor(tester, find.text('CUSTOM APPS')),
      isTrue,
      reason: 'custom section did not appear after adding YouTube',
    );
    expect(find.text(kYouTube), findsOneWidget, reason: 'YouTube row missing');
    final savedApps = await sl<AppBlockRepository>().load();
    expect(
      savedApps.where((e) => e.packageName == kYouTube && e.enabled),
      hasLength(1),
      reason: 'YouTube block not persisted as enabled',
    );
    await step(tester, 'app-blocker-added');

    // Driver: launches YouTube, expects `blocked app_block in <pkg> via HOME`.
    await probe(tester, 'app');
    expect(
      await waitFor(tester, find.text('Block apps')),
      isTrue,
      reason: 'did not come back to the App Blocker screen after the probe',
    );

    // Cleanup: remove the lock (pushes an explicit [] to native).
    await tester.tap(find.byTooltip('Remove YouTube'));
    expect(
      await waitForGone(tester, find.text(kYouTube)),
      isTrue,
      reason: 'YouTube row did not go away',
    );
    await tester.pageBack();
    expect(await waitFor(tester, home), isTrue, reason: 'no way back to /home');

    // ── Web Blocker: add example.com, get blocked, pause, get through ───────
    await openTile(tester, 'Web Blocker');
    expect(
      await waitFor(tester, find.text('Website blocker')),
      isTrue,
      reason: 'Web Blocker screen did not open',
    );
    await step(tester, 'web-blocker');

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Add website'));
    await settle(tester, frames: 8);
    await tester.enterText(find.byType(TextField).last, kSite);
    await tester.tap(find.text('Block website'));
    // The sheet's field also matches find.text(kSite) — wait for it to close.
    expect(
      await waitForGone(tester, find.text('Block website')),
      isTrue,
      reason: 'add-website sheet did not close',
    );
    // Scoped to the row card: once the first block lands, the stats section
    // also renders the host as plain text ("Most blocked: example.com").
    final row = find.widgetWithText(AppCard, kSite);
    expect(await waitFor(tester, row), isTrue, reason: 'site row missing');
    await step(tester, 'web-blocker-added');

    // Driver: opens https://example.com in Chrome, expects `web-blocked`.
    await probe(tester, 'web');
    expect(
      await waitFor(tester, find.text('Website blocker')),
      isTrue,
      reason: 'did not come back to the Web Blocker screen after the probe',
    );

    // Pause the site for 5 min: tap the row (opens the swipe pane) → Pause.
    await tester.tap(row);
    await settle(tester, frames: 8);
    await tester.tap(find.text('Allow'));
    await settle(tester, frames: 8);
    await tester.tap(find.text('5 min'));
    expect(
      await waitFor(tester, find.textContaining('Allowed until')),
      isTrue,
      reason: 'allow pill did not appear',
    );
    // M8: the window is a WEBSITE grant now, not a field on the blocklist
    // entry — one mechanism for reels, apps and sites.
    final grants = await sl<TemporaryUnblockRepository>().load();
    expect(
      grants.where(
        (g) =>
            g.targetType == UnblockTargetType.website &&
            g.targetId == kSite &&
            g.isActiveAt(DateTime.now().millisecondsSinceEpoch),
      ),
      hasLength(1),
      reason: 'grant not persisted',
    );
    await step(tester, 'web-blocker-paused');

    // Driver: opens the site again, expects NO `web-blocked` line.
    await probe(tester, 'web-paused');
    expect(
      await waitFor(tester, find.text('Website blocker')),
      isTrue,
      reason: 'did not come back to the Web Blocker screen after the probe',
    );

    // Cleanup: delete the entry via the swipe pane.
    await tester.tap(row);
    await settle(tester, frames: 8);
    await tester.tap(find.text('Delete'));
    expect(
      await waitForGone(tester, row),
      isTrue,
      reason: 'example.com row did not go away',
    );
    await tester.pageBack();
    expect(await waitFor(tester, home), isTrue, reason: 'no way back to /home');
    await step(tester, 'home-final');
  });
}
