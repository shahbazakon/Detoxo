import 'dart:async';

import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_stats.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockWebRepo extends Mock implements WebBlockRepository {}

class _MockSettingsRepo extends Mock implements SettingsRepository {}

class _MockAppBlockRepo extends Mock implements AppBlockRepository {}

class _MockStatsRepo extends Mock implements WebBlockStatsRepository {}

class _MockEngine extends Mock implements EngineRepository {}

// AppTheme pulls google_fonts, which stalls under flutter_test — the screen
// only needs GlassTokens plus a ColorScheme (same idiom as app_picker_test).
ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

/// Regression tests for the `!semantics.parentDataDirty` framework assertion:
/// with semantics enabled (TalkBack, or any debug session after the first
/// `SemanticsBinding` client attaches), structural changes inside this
/// screen's ListView — the stats section appearing on the first webBlocked
/// event, rows appearing/disappearing — must not corrupt the semantics tree.
/// Seen live on-device 2026-08-17: first block while the screen was open
/// blanked the body and error-looped into a Crashlytics OOM.
void main() {
  late _MockWebRepo repo;
  late _MockSettingsRepo settings;
  late _MockAppBlockRepo appBlocks;
  late _MockStatsRepo statsRepo;
  late _MockEngine engine;
  late StreamController<WebBlockStats> statsCtrl;

  setUp(() async {
    await sl.reset();
    repo = _MockWebRepo();
    settings = _MockSettingsRepo();
    appBlocks = _MockAppBlockRepo();
    statsRepo = _MockStatsRepo();
    engine = _MockEngine();
    statsCtrl = StreamController<WebBlockStats>.broadcast();
    when(() => repo.load()).thenAnswer(
      (_) async => [
        WebBlockEntry(pattern: 'example.com', createdAt: DateTime(2026)),
      ],
    );
    when(() => settings.load()).thenAnswer((_) async => const AppSettings());
    when(() => appBlocks.load()).thenAnswer((_) async => const []);
    when(() => statsRepo.load()).thenAnswer((_) async => const WebBlockStats());
    when(() => statsRepo.watch()).thenAnswer((_) => statsCtrl.stream);
    when(() => engine.pushWebBlocklist(any())).thenAnswer((_) async {});
    sl
      ..registerSingleton<WebBlockRepository>(repo)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<AppBlockRepository>(appBlocks)
      ..registerSingleton<WebBlockStatsRepository>(statsRepo)
      ..registerSingleton<EngineRepository>(engine);
  });

  tearDown(() async {
    await statsCtrl.close();
    await sl.reset();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: _theme(), home: const WebBlockScreen()),
    );
    await tester.pump(); // load() future completes
    // Entrance animations (fadeIn/slideY). Never pumpAndSettle: the
    // GlassScaffold ambient background repeats forever.
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('first stats event while open keeps semantics alive', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpScreen(tester);
    expect(find.text('Blocked today'), findsNothing);

    // First-ever webBlocked event → hasStats flips → stats section inserted.
    statsCtrl.add(
      const WebBlockStats(
        totalBlocked: 1,
        blockedToday: 1,
        mostBlockedHost: 'example.com',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.takeException(), isNull);
    expect(find.text('Blocked today'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('row toggle flip (pause button appears/disappears) is safe', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    when(() => repo.save(any())).thenAnswer((_) async {});
    registerFallbackValue(<WebBlockEntry>[]);
    await pumpScreen(tester);

    // Disable → the conditional pause action unmounts from the swipe pane.
    await tester.tap(find.bySemanticsLabel('Block example.com'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    // Re-enable → it mounts again.
    await tester.tap(find.bySemanticsLabel('Block example.com'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('swipe pane reveals delete and removes the row', (tester) async {
    when(() => repo.save(any())).thenAnswer((_) async {});
    registerFallbackValue(<WebBlockEntry>[]);
    await pumpScreen(tester);
    expect(find.text('Delete'), findsNothing);

    // Swipe the row left to open the end action pane.
    await tester.drag(find.text('example.com'), const Offset(-300, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.takeException(), isNull);
    final saved =
        verify(() => repo.save(captureAny())).captured.single
            as List<WebBlockEntry>;
    expect(saved, isEmpty);
    expect(find.text('example.com'), findsNothing);
  });
}
