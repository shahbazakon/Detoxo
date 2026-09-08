import 'dart:async';

import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/limits/rules/presentation/rules_screen.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

class _FakeRules implements RuleRepository {
  _FakeRules(this.rules);
  List<Rule> rules;

  @override
  Future<List<Rule>> load() async => rules;

  @override
  Future<void> save(List<Rule> next) async => rules = next;
}

class _FakeDailyLimit implements DailyLimitRepository {
  @override
  Future<DailyLimit> load() async => const DailyLimit();

  @override
  Future<void> save(DailyLimit limit) async {}
}

class _FakeUsage implements UsageRepository {
  @override
  Future<bool?> hasAccess() async => false;

  @override
  Future<UsageQueryResult<List<AppUsage>>> queryAppUsage(
    DateTime start,
    DateTime end,
  ) async => const UsageDenied();

  @override
  Future<UsageQueryResult<List<UsageEvent>>> queryUsageEvents(
    DateTime start,
    DateTime end,
  ) async => const UsageDenied();
}

// AppTheme pulls google_fonts, which stalls under flutter_test — the screen
// only needs GlassTokens plus a ColorScheme (the web_block_screen idiom).
ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

const _limitRule = Rule(
  id: 't1',
  name: 'Insta budget',
  kind: RuleKind.timeLimit,
  createdAtMs: 1,
  selection: RuleSelection(apps: ['com.instagram.android']),
  thresholdMs: 30 * 60000,
);

/// Same `!semantics.parentDataDirty` regression class as
/// `web_block_screen_semantics_test.dart` (seen live on-device 2026-08-17).
/// This list is MORE exposed than that one: the usage-access hint, the pinned
/// daily-limit row and every status pill mount and unmount from `resync()`,
/// which fires on a native `ruleBoundary` event and on a self-armed timer
/// while the screen is open.
void main() {
  // Built INSIDE the test body, never in setUp: a cubit constructed outside
  // testWidgets' FakeAsync zone owns futures that zone never pumps, and the
  // first `await` on one of them deadlocks the test.
  Future<(RulesCubit, StreamController<int>)> pumpScreen(
    WidgetTester tester,
  ) async {
    final engine = _MockEngine();
    // ignore: close_sinks — handed back and closed by each test body.
    final boundaries = StreamController<int>.broadcast();
    when(() => engine.pushRules(any(), any())).thenAnswer((_) async => true);
    when(engine.ruleBoundaryStream).thenAnswer((_) => boundaries.stream);
    final rules = RulesCubit(
      _FakeRules([_limitRule]),
      _FakeDailyLimit(),
      _FakeUsage(),
      engine,
      clock: () => DateTime(2026, 9, 2, 10),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: rules),
            BlocProvider(create: (_) => DailyLimitCubit(_FakeDailyLimit())),
          ],
          child: const RulesScreen(),
        ),
      ),
    );
    await tester.pump();
    // Entrance animations. Never pumpAndSettle: the GlassScaffold ambient
    // background repeats forever.
    await tester.pump(const Duration(milliseconds: 700));
    return (rules, boundaries);
  }

  testWidgets('a ruleBoundary while open keeps semantics alive', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final (rules, boundaries) = await pumpScreen(tester);
    await rules.load();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    // The usage-access hint mounts once resync answers "denied" — a structural
    // insert above the list, exactly what corrupted the sibling's tree.
    expect(find.byType(RulesScreen), findsOneWidget);

    boundaries.add(DateTime(2026, 9, 2, 17).millisecondsSinceEpoch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.takeException(), isNull);
    await rules.close();
    await boundaries.close();
    semantics.dispose();
  });

  testWidgets('toggling a rule off re-renders its pill safely', (tester) async {
    final semantics = tester.ensureSemantics();
    final (rules, boundaries) = await pumpScreen(tester);
    await rules.load();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(find.bySemanticsLabel('Enable Insta budget'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.takeException(), isNull);
    expect(rules.state.rules.single.enabled, isFalse);
    await rules.close();
    await boundaries.close();
    semantics.dispose();
  });
}
