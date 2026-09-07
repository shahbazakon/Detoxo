import 'dart:async';

import 'package:detoxo/core/design_system/components/cards.dart';
import 'package:detoxo/core/design_system/foundations/glass_container.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/analytics/insights/presentation/widgets/insights_view.dart';
import 'package:detoxo/features/analytics/presentation/analytics_screen.dart';
import 'package:detoxo/features/analytics/presentation/widgets/app_limit_row.dart';
import 'package:detoxo/features/analytics/presentation/widgets/by_app_section.dart';
import 'package:detoxo/features/analytics/presentation/widgets/today_overview.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

class _MockCounter extends Mock implements ContentCounterRepository {}

class _MockBubble extends Mock implements BubbleRepository {}

/// A pinned screen-time answer: granted with [stats], denied when null.
/// Mutable so a test can revoke and restore the grant between refreshes.
class _FakeInsights implements InsightsRepository {
  _FakeInsights({this.stats, this.yesterday});

  DailyStats? stats;
  final DailyStats? yesterday;

  @override
  Future<UsageQueryResult<DailyStats>> today() async =>
      stats == null ? const UsageDenied() : UsageGranted(stats!);

  @override
  DailyStats? cached(String dayKey) => yesterday;

  @override
  Future<bool?> hasAccess() async => stats != null;
}

class _EmptyGrants implements TemporaryUnblockRepository {
  @override
  Future<List<TemporaryUnblock>> load() async => const [];

  @override
  Future<void> save(List<TemporaryUnblock> grants) async {}
}

class _EmptyLedger implements BypassLedgerRepository {
  @override
  Future<BypassLedger> load() async => const BypassLedger();

  @override
  Future<void> save(BypassLedger ledger) async {}
}

// AppTheme pulls google_fonts, which stalls under flutter_test — the screen
// only needs GlassTokens plus a ColorScheme (the web_block_screen idiom).
ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

/// A quiet, granted hour of screen time.
final _quietHour = DailyStats(
  dayKey: '02-09-2026',
  screenTimeMs: const Duration(hours: 1).inMilliseconds,
);

/// The restructured Activity screen: three headed sections — Today (flat
/// tiles in one panel), Distraction, By app (a segmented control over one
/// panel of rows) — then the Overrides card last. The native
/// block counters land in the Today tiles (yesterday and all-time beside
/// today) and the per-app tally sits behind the Blocks segment. The repo
/// idiom is `test/web_block_screen_semantics_test.dart`: real cubits over
/// fakes in `sl`.
void main() {
  late _MockEngine engine;
  late _MockCounter counter;
  late _MockBubble bubble;
  late StreamController<ServiceSnapshot> status;

  setUp(() async {
    await sl.reset();
    engine = _MockEngine();
    counter = _MockCounter();
    bubble = _MockBubble();
    status = StreamController<ServiceSnapshot>.broadcast();
    when(() => engine.statusStream()).thenAnswer((_) => status.stream);
    // No installed-app labels: rows fall back to package names.
    when(() => engine.installedApps()).thenAnswer((_) async => null);
    when(() => engine.pushTemporaryUnblocks(any())).thenAnswer((_) async {});
    when(() => engine.takePendingUnblock()).thenAnswer((_) async => null);
    when(() => engine.takeNativeGrants()).thenAnswer((_) async => null);
    when(
      () => counter.watch(),
    ).thenAnswer((_) => Stream.value(const ContentCount(today: 5, total: 50)));
    when(() => bubble.canShow()).thenAnswer((_) async => true);
    sl.registerSingleton<EngineRepository>(engine);
  });

  tearDown(() async {
    await status.close();
    await sl.reset();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    InsightsRepository? insights,
  }) async {
    // Tall enough that the whole scroll is built, so the order can be read.
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => ServiceCubit(engine)),
          BlocProvider(
            create: (_) => InsightsCubit(
              insights ?? _FakeInsights(stats: _quietHour),
              engine,
              clock: () => DateTime(2026, 9, 2, 12),
            ),
          ),
          BlocProvider(create: (_) => ContentCounterCubit(counter, bubble)),
          BlocProvider(
            create: (_) =>
                UnblockCubit(_EmptyGrants(), _EmptyLedger(), engine)..load(),
          ),
        ],
        child: MaterialApp(theme: _theme(), home: const AnalyticsScreen()),
      ),
    );
    await tester.pump();
    // Entrance animations and count-ups. Never pumpAndSettle: the
    // GlassScaffold ambient background repeats forever.
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> pushStatus(WidgetTester tester, ServiceSnapshot snap) async {
    status.add(snap);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> selectSegment(WidgetTester tester, String label) async {
    // The segmented control's hit layer sits above its labels, so the label
    // itself never hit-tests; the tap still lands on the control.
    await tester.tap(find.text(label), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('native counters land in the tiles and the per-app rows', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester);
    expect(find.text('Blocked'), findsOneWidget);
    await selectSegment(tester, 'Blocks');
    expect(find.text('No blocks yet today.'), findsOneWidget);

    await pushStatus(
      tester,
      const ServiceSnapshot(
        status: ServiceStatus.running,
        blocksToday: 12,
        blocksTotal: 340,
        blocksYesterday: 52,
        blocksByPackage: {
          'com.instagram.android': 9,
          'com.google.android.youtube': 3,
        },
      ),
    );

    expect(tester.takeException(), isNull);
    // One spoken sentence per tile, yesterday as the one plain reference
    // (all-time steps aside once there is a yesterday). The card merges its
    // non-interactive children into one node, so the tile is pinned as a
    // substring.
    expect(
      tester.getSemantics(find.byType(StatCard).at(1)).label,
      contains('Blocked: 12, Yesterday: 52'),
    );
    expect(find.text('Yesterday: 52'), findsOneWidget);
    expect(find.textContaining('All time: 340'), findsNothing);
    // The tally, most-blocked first, each row a way to a limit.
    expect(find.text('No blocks yet today.'), findsNothing);
    expect(
      tester.getSemantics(find.byType(AppLimitRow).first),
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'com.instagram.android, 9 blocks. Set a daily limit',
      ),
    );
    expect(
      tester.getTopLeft(find.text('com.instagram.android')).dy,
      lessThan(tester.getTopLeft(find.text('com.google.android.youtube')).dy),
    );
    semantics.dispose();
  });

  testWidgets('the scroll reads today, distraction, then by app', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester);
    await pushStatus(
      tester,
      const ServiceSnapshot(
        status: ServiceStatus.running,
        blocksToday: 1,
        blocksTotal: 1,
        blocksByPackage: {'com.instagram.android': 1},
      ),
    );

    final today = tester.getTopLeft(find.byType(TodayOverview)).dy;
    final distraction = tester.getTopLeft(find.byType(InsightsView)).dy;
    final byApp = tester.getTopLeft(find.byType(ByAppSection)).dy;
    expect(today, lessThan(distraction));
    expect(distraction, lessThan(byApp));
    // Three uppercase section headers, each a heading a screen reader can
    // jump to — the AppCard titles they replaced were headings too.
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('DISTRACTION'), findsOneWidget);
    expect(find.text('BY APP'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('TODAY')).flagsCollection.isHeader,
      isTrue,
    );
    // One glass surface per section — the panel. The tiles inside are
    // flat, so nothing is glass-on-glass any more.
    expect(
      find.descendant(
        of: find.byType(TodayOverview),
        matching: find.byType(GlassContainer),
      ),
      findsOneWidget,
    );
    // Detoxo's own counts never need the permission; the OS figures join
    // them in the same grid once it is granted. `Reels` is scoped: the
    // segment pill below says it too.
    expect(
      find.descendant(
        of: find.byType(TodayOverview),
        matching: find.text('Reels'),
      ),
      findsOneWidget,
    );
    expect(find.text('Screen time'), findsOneWidget);
    expect(find.text('1h'), findsOneWidget);
    // The source note moved behind the header's info button — one, on this
    // header only, and no paragraph under the sections.
    expect(find.byTooltip('About these numbers'), findsOneWidget);
    expect(find.textContaining('Digital Wellbeing'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a fresh install claims no yesterday, nor does day one', (
    tester,
  ) async {
    await pumpScreen(tester);
    await pushStatus(
      tester,
      const ServiceSnapshot(status: ServiceStatus.running),
    );

    expect(find.textContaining('Yesterday'), findsNothing);
    expect(find.text('All time: 50'), findsOneWidget);

    // The first blocks ever: the total equals today, so there is no earlier
    // day to refer to — "Yesterday: 0" would claim one.
    await pushStatus(
      tester,
      const ServiceSnapshot(
        status: ServiceStatus.running,
        blocksToday: 3,
        blocksTotal: 3,
      ),
    );
    expect(find.textContaining('Yesterday'), findsNothing);
    expect(find.text('All time: 3'), findsOneWidget);
  });

  testWidgets('the Reels segment draws the counter rows by display name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    when(() => counter.watch()).thenAnswer(
      (_) => Stream.value(
        const ContentCount(
          today: 5,
          total: 50,
          perAppToday: [
            AppContentCount(
              packageName: 'com.instagram.android',
              appName: 'Instagram',
              displayName: 'Instagram Reels',
              iconUrl: '',
              count: 4,
            ),
            AppContentCount(
              packageName: 'com.google.android.youtube',
              appName: 'YouTube',
              displayName: 'YouTube Shorts',
              iconUrl: '',
              count: 1,
            ),
          ],
        ),
      ),
    );
    await pumpScreen(tester);

    // No installed-app labels, so the counter's own display name is used
    // before the package name.
    expect(find.text('Instagram Reels'), findsOneWidget);
    expect(find.text('YouTube Shorts'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(AppLimitRow).first),
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'Instagram Reels, 4 reels. Set a daily limit',
      ),
    );
    expect(
      tester.getSemantics(find.byType(AppLimitRow).last),
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'YouTube Shorts, 1 reel. Set a daily limit',
      ),
    );
    semantics.dispose();
  });

  testWidgets('a revoked grant drops Time under a selection and restores it', (
    tester,
  ) async {
    final granted = DailyStats(
      dayKey: '02-09-2026',
      screenTimeMs: const Duration(hours: 2).inMilliseconds,
      topApps: const [
        AppUsage(package: 'com.instagram.android', foregroundMillis: 4200000),
      ],
    );
    final insights = _FakeInsights(stats: granted);
    await pumpScreen(tester, insights: insights);
    await selectSegment(tester, 'Time');
    expect(find.text('1h 10m'), findsOneWidget);

    Future<void> refresh() async {
      await tester
          .element(find.byType(ByAppSection))
          .read<InsightsCubit>()
          .refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
    }

    // Revoked in Settings: the segment is gone and the rows fall back to
    // Blocks — pill and rows agree.
    insights.stats = null;
    await refresh();
    expect(find.text('Time'), findsNothing);
    expect(find.text('1h 10m'), findsNothing);
    expect(find.text('No blocks yet today.'), findsOneWidget);

    // Granted again: the earlier choice re-selects itself.
    insights.stats = granted;
    await refresh();
    expect(find.text('Time'), findsOneWidget);
    expect(find.text('1h 10m'), findsOneWidget);
  });

  testWidgets(
    'without usage access the OS tiles and the Time segment are gone',
    (tester) async {
      await pumpScreen(tester, insights: _FakeInsights());

      expect(
        find.descendant(
          of: find.byType(TodayOverview),
          matching: find.text('Reels'),
        ),
        findsOneWidget,
      );
      expect(find.text('Blocked'), findsOneWidget);
      expect(find.text('Screen time'), findsNothing);
      expect(find.text('Pickups'), findsNothing);
      expect(find.text('Usage access'), findsOneWidget);
      expect(find.text('Time'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ByAppSection),
          matching: find.text('Reels'),
        ),
        findsOneWidget,
      );
      expect(find.text('Blocks'), findsOneWidget);
    },
  );

  testWidgets('a complete yesterday and the top app land in their places', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(
      tester,
      insights: _FakeInsights(
        stats: DailyStats(
          dayKey: '02-09-2026',
          screenTimeMs: const Duration(hours: 3, minutes: 12).inMilliseconds,
          pickupCount: 84,
          firstPickupMs: DateTime(2026, 9, 2, 7, 12).millisecondsSinceEpoch,
          lastPickupMs: DateTime(2026, 9, 2, 22, 40).millisecondsSinceEpoch,
          topApps: const [
            AppUsage(
              package: 'com.instagram.android',
              foregroundMillis: 4200000,
            ),
          ],
        ),
        yesterday: DailyStats(
          dayKey: '01-09-2026',
          screenTimeMs: const Duration(hours: 4).inMilliseconds,
          complete: true,
        ),
      ),
    );

    expect(find.text('3h 12m'), findsOneWidget);
    // Never a percentage while today is still running: a part-day against a
    // whole one reads as a triumph every morning.
    expect(find.text('Yesterday: 4h'), findsOneWidget);
    expect(find.textContaining('than yesterday'), findsNothing);
    expect(find.text('Pickups'), findsOneWidget);
    expect(find.textContaining('First 7:12'), findsOneWidget);
    // One reference per tile: the last pickup no longer rides along.
    expect(find.textContaining('Last'), findsNothing);

    await selectSegment(tester, 'Time');
    // No installed-app match, so it falls back to the package name.
    expect(find.text('com.instagram.android'), findsOneWidget);
    expect(find.text('1h 10m'), findsOneWidget);
    // EVO-033: the row is the entry point to a limit, not just a readout.
    expect(
      tester.getSemantics(find.byType(AppLimitRow).first),
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'com.instagram.android, 1h 10m. Set a daily limit',
      ),
    );
    semantics.dispose();
  });
}
