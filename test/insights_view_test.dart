import 'package:detoxo/core/theme/app_theme.dart';
import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/analytics/insights/presentation/widgets/insights_view.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

/// An insights repository with a pinned answer.
class _FakeRepo implements InsightsRepository {
  _FakeRepo(this.result, {this.yesterday});

  UsageQueryResult<DailyStats> result;
  DailyStats? yesterday;

  @override
  Future<UsageQueryResult<DailyStats>> today() async => result;

  @override
  DailyStats? cached(String dayKey) => yesterday;

  @override
  Future<bool?> hasAccess() async => result is! UsageDenied;
}

/// EVO-014 on a new surface: a missing grant and a failed read must each say so
/// in their own words. A `0 m` here would be indistinguishable from a genuinely
/// quiet day — a confident lie about the user's own behaviour.
void main() {
  late _MockEngine engine;

  setUp(() {
    engine = _MockEngine();
    when(() => engine.installedApps()).thenAnswer((_) async => const []);
  });

  /// Mounts the view over a repository the caller keeps a handle on, so a
  /// retry can be made to return something different the second time.
  Future<void> pumpRepo(WidgetTester tester, _FakeRepo repo) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: BlocProvider(
            create: (_) => InsightsCubit(
              repo,
              engine,
              clock: () => DateTime(2026, 9, 2, 12),
            )..load(),
            child: const SingleChildScrollView(child: InsightsView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pump(
    WidgetTester tester,
    UsageQueryResult<DailyStats> result, {
    DailyStats? yesterday,
  }) => pumpRepo(tester, _FakeRepo(result, yesterday: yesterday));

  testWidgets('denied offers the grant and never prints a zero', (
    tester,
  ) async {
    await pump(tester, const UsageDenied());

    expect(find.text('Usage access'), findsOneWidget);
    expect(find.text('Grant'), findsOneWidget);
    expect(find.text('Checking…'), findsNothing);
    expect(find.textContaining('0m'), findsNothing);
    expect(find.textContaining('Screen time'), findsNothing);
  });

  testWidgets('unavailable renders the neutral state, not a denial', (
    tester,
  ) async {
    await pump(tester, const UsageUnavailable());

    expect(find.text('Checking…'), findsOneWidget);
    expect(find.text('Grant'), findsNothing);
    expect(find.textContaining('0m'), findsNothing);
  });

  testWidgets('unavailable offers a Retry that actually recomputes', (
    tester,
  ) async {
    // The card used to advertise nothing at all here: PermissionCard drew the
    // "Checking…" row and dropped the action, so a failed read was a dead end
    // recoverable only by an undiscoverable pull-to-refresh.
    final repo = _FakeRepo(const UsageUnavailable());
    await pumpRepo(tester, repo);
    expect(find.text('Retry'), findsOneWidget);

    repo.result = UsageGranted(
      DailyStats(
        dayKey: '02-09-2026',
        screenTimeMs: const Duration(hours: 1).inMilliseconds,
      ),
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('App switches'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('granted draws the real figures', (tester) async {
    await pump(
      tester,
      UsageGranted(
        DailyStats(
          dayKey: '02-09-2026',
          screenTimeMs: const Duration(hours: 3, minutes: 12).inMilliseconds,
          distractionMs: const Duration(hours: 1, minutes: 48).inMilliseconds,
          pickupCount: 84,
          contextSwitches: 142,
          distractionOpens: 37,
          reelCount: 96,
        ),
      ),
    );

    expect(find.text('1h 48m · 56% of screen time'), findsOneWidget);
    // The section header — uppercase, and there in every state, which is why
    // the other tests pin a granted-only string instead.
    expect(find.text('DISTRACTION'), findsOneWidget);
    expect(find.text('App switches'), findsOneWidget);
    expect(find.text('Distracting opens'), findsOneWidget);
    // The headline figures (screen time, pickups, reels) are the Activity
    // screen's Today grid — a second, snapshot copy here would disagree with
    // the live one by evening.
    expect(find.text('3h 12m'), findsNothing);
    expect(find.text('Reels'), findsNothing);
    expect(find.text('Usage access'), findsNothing);
  });

  testWidgets('a genuinely quiet day says so instead of nothing', (
    tester,
  ) async {
    await pump(tester, const UsageGranted(DailyStats(dayKey: '02-09-2026')));

    expect(find.text('Nothing yet today'), findsOneWidget);
    // Crucially, this is NOT the denied state.
    expect(find.text('Grant'), findsNothing);
  });

  testWidgets('the info button opens the note on where the numbers come from', (
    tester,
  ) async {
    await pump(tester, const UsageGranted(DailyStats(dayKey: '02-09-2026')));
    // Nothing on the screen itself; the note is one tap away.
    expect(find.textContaining('Digital Wellbeing'), findsNothing);

    await tester.tap(find.byTooltip('About these numbers'));
    await tester.pumpAndSettle();

    expect(find.text('About these numbers'), findsOneWidget);
    expect(find.textContaining('Digital Wellbeing'), findsOneWidget);
  });

  // EVO-058: the cubit outlives the view (app-wide, lazy). The shell rebuilds
  // the Activity tab on every switch; a later mount must paint the last
  // numbers on its first frame and refresh them in place, never spin.
  testWidgets('a later mount keeps the numbers on screen while refreshing', (
    tester,
  ) async {
    final repo = _FakeRepo(
      UsageGranted(
        DailyStats(
          dayKey: '02-09-2026',
          screenTimeMs: const Duration(hours: 1).inMilliseconds,
        ),
      ),
    );
    final cubit = InsightsCubit(
      repo,
      engine,
      clock: () => DateTime(2026, 9, 2, 12),
    );
    Future<void> mount() => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const SingleChildScrollView(child: InsightsView()),
          ),
        ),
      ),
    );

    await mount();
    await tester.pumpAndSettle();
    expect(find.text('App switches'), findsOneWidget);

    // Leave the tab and come back.
    await tester.pumpWidget(const SizedBox());
    await mount();

    expect(find.text('Reading your screen time…'), findsNothing);
    expect(find.text('App switches'), findsOneWidget);
    await tester.pumpAndSettle();
    await cubit.close();
  });
}
