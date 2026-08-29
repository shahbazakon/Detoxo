// M8 — the wall's "Unblock for a while" hand-off, end to end through the widget
// tree it actually runs in.
//
// This file exists because the sheet is opened from `MaterialApp.router`'s
// `builder`, which sits ABOVE the routed Navigator: a `showModalBottomSheet` on
// that context finds no Navigator and throws, and nothing else in the suite
// mounts the widget in that position. So the shape below is deliberately the
// real one — router, builder, gate — not a convenient stand-in.

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/app_gate.dart';
import 'package:detoxo/core/navigation/app_router.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/limits/unblock/presentation/widgets/pending_unblock_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

class _FakeGrants implements TemporaryUnblockRepository {
  List<TemporaryUnblock> rows = const [];

  @override
  Future<List<TemporaryUnblock>> load() async => rows;

  @override
  Future<void> save(List<TemporaryUnblock> grants) async => rows = grants;
}

class _FakeLedger implements BypassLedgerRepository {
  @override
  Future<BypassLedger> load() async => const BypassLedger();

  @override
  Future<void> save(BypassLedger ledger) async {}
}

ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

void main() {
  late _MockEngine engine;
  late _FakeGrants grants;
  late AppGate gate;

  setUp(() async {
    await sl.reset();
    engine = _MockEngine();
    grants = _FakeGrants();
    gate = AppGate();
    when(() => engine.pushTemporaryUnblocks(any())).thenAnswer((_) async {});
    when(
      () => engine.takePendingUnblock(),
    ).thenAnswer((_) async => 'APP|com.instagram.android');
    sl.registerSingleton<AppGate>(gate);
  });

  tearDown(() async {
    await sl.reset();
  });

  /// Pumps until [finder]'s widget is actually inside the surface. The sheet
  /// slides up, and `pumpAndSettle` is not an option here (the glass surfaces
  /// carry an ambient animation that never settles).
  Future<void> settleIn(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isEmpty) {
        continue;
      }
      final rect = tester.getRect(finder);
      final surface = tester.getSize(find.byType(MaterialApp)).height;
      if (rect.bottom <= surface) return;
    }
  }

  /// The real shape: a router whose `builder` hosts the listener, so the sheet
  /// has to reach the Navigator the same way it does in `main.dart`.
  Future<UnblockCubit> pump(WidgetTester tester) async {
    // The default 800x600 surface lays the sheet's chips out below the fold, so
    // a tap misses them. Tall enough that the whole sheet is on screen.
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cubit = UnblockCubit(grants, _FakeLedger(), engine);
    await cubit.load();
    // The production key, on purpose: it is what the listener reaches through,
    // so a test router with its own key would pass while the app was broken.
    final router = GoRouter(
      navigatorKey: appNavigatorKey,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
      ],
    );
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp.router(
          theme: _theme(),
          routerConfig: router,
          builder: (context, child) =>
              PendingUnblockListener(child: child ?? const SizedBox()),
        ),
      ),
    );
    await tester.pump();
    return cubit;
  }

  testWidgets('a pending target opens the duration sheet and grants', (
    tester,
  ) async {
    gate.update(ready: true, onboarded: true);
    final cubit = await pump(tester);

    await cubit.takePending();
    await settleIn(tester, find.text('15 min'));

    expect(
      find.text('Allow this app for…'),
      findsOneWidget,
      reason:
          'the sheet is pushed through the router navigator key — the builder '
          'context it is mounted in has no Navigator of its own',
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('15 min'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(cubit.state.active, hasLength(1));
    expect(cubit.state.active.single.targetId, 'com.instagram.android');
    expect(cubit.state.pending, isNull, reason: 'consumed exactly once');
    await cubit.close();
  });

  testWidgets('backing out of the sheet grants nothing', (tester) async {
    gate.update(ready: true, onboarded: true);
    final cubit = await pump(tester);

    await cubit.takePending();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Allow this app for…'), findsOneWidget);

    appNavigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(cubit.state.grants, isEmpty);
    expect(cubit.state.pending, isNull);
    await cubit.close();
  });

  testWidgets('a tap that lands on a PIN-locked launch is held, not dropped', (
    tester,
  ) async {
    // The tap IS what launches Detoxo, so it usually arrives before the gate
    // opens. Consuming it there would make the button silently do nothing.
    gate.update(ready: true, onboarded: true, pinLocked: true);
    final cubit = await pump(tester);

    await cubit.takePending();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Allow this app for…'), findsNothing);
    expect(cubit.state.pending, isNotNull, reason: 'held, not consumed');

    gate.unlockPin();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Allow this app for…'), findsOneWidget);
    expect(cubit.state.pending, isNull);
    await cubit.close();
  });
}
