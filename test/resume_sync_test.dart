import 'package:detoxo/app/app_resume_sync.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/engine/presentation/service_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/content_counter_cubit.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockPermissions extends Mock implements PermissionsCubit {}

class _MockService extends Mock implements ServiceCubit {}

class _MockCounter extends Mock implements ContentCounterCubit {}

class _MockSettings extends Mock implements SettingsCubit {}

class _MockTargets extends Mock implements TargetsCubit {}

class _MockEngineRepo extends Mock implements EngineRepository {}

class _MockWebBlocks extends Mock implements WebBlockRepository {}

class _MockAppBlocks extends Mock implements AppBlockRepository {}

class _MockSettingsRepo extends Mock implements SettingsRepository {}

class _MockProtected extends Mock implements ProtectedAppsRepository {}

class _MockRules extends Mock implements RulesCubit {}

void main() {
  late _MockPermissions permissions;
  late _MockService service;
  late _MockCounter counter;
  late _MockSettings settings;
  late _MockTargets targets;
  late _MockRules rules;

  setUp(() {
    permissions = _MockPermissions();
    service = _MockService();
    counter = _MockCounter();
    settings = _MockSettings();
    targets = _MockTargets();
    rules = _MockRules();
    when(() => permissions.refresh()).thenAnswer((_) async {});
    when(() => service.refresh()).thenAnswer((_) async {});
    when(() => counter.refresh()).thenAnswer((_) async {});
    when(() => settings.resync()).thenAnswer((_) async {});
    when(() => rules.resync()).thenAnswer((_) async {});
    when(() => targets.load()).thenAnswer((_) async {});
    // BlocProvider subscribes to the cubit's stream on first read.
    when(() => permissions.stream).thenAnswer((_) => const Stream.empty());
    when(() => service.stream).thenAnswer((_) => const Stream.empty());
    when(() => counter.stream).thenAnswer((_) => const Stream.empty());
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    when(() => targets.stream).thenAnswer((_) => const Stream.empty());
    when(() => rules.stream).thenAnswer((_) => const Stream.empty());
  });

  List<BlocProvider> providers() => [
    BlocProvider<PermissionsCubit>.value(value: permissions),
    BlocProvider<ServiceCubit>.value(value: service),
    BlocProvider<ContentCounterCubit>.value(value: counter),
    BlocProvider<SettingsCubit>.value(value: settings),
    BlocProvider<TargetsCubit>.value(value: targets),
    BlocProvider<RulesCubit>.value(value: rules),
  ];

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MultiBlocProvider(
      providers: providers(),
      child: const AppResumeSync(child: SizedBox()),
    ),
  );

  testWidgets('resume fires the cheap refreshes', (tester) async {
    await pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    verify(() => permissions.refresh()).called(1);
    verify(() => service.refresh()).called(1);
    verify(() => counter.refresh()).called(1);
    verify(() => settings.resync()).called(1);
    // Rules re-resolve on every resume: the 7-day window horizon rolls
    // forward and spent limits reconcile against today's UsageStats.
    verify(() => rules.resync()).called(1);
  });

  testWidgets('the heavy leg is throttled right after a cold start', (
    tester,
  ) async {
    // The splash just ran the same syncs, so a resume minutes later must not
    // re-run the native installed-apps scan.
    await pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    verifyNever(() => targets.load());
  });

  testWidgets('past the throttle, the heavy leg re-syncs everything', (
    tester,
  ) async {
    // Pin the positive path (a zero interval stands in for ">= 15 min since
    // cold start"): config re-push + all three blocklist/protection syncs.
    final engineRepo = _MockEngineRepo();
    final webBlocks = _MockWebBlocks();
    final appBlocks = _MockAppBlocks();
    final settingsRepo = _MockSettingsRepo();
    final protectedApps = _MockProtected();
    when(webBlocks.load).thenAnswer((_) async => const []);
    when(appBlocks.load).thenAnswer((_) async => const []);
    when(protectedApps.load).thenAnswer((_) async => const []);
    when(settingsRepo.load).thenAnswer((_) async => const AppSettings());
    when(() => engineRepo.pushWebBlocklist(any())).thenAnswer((_) async {});
    when(() => engineRepo.pushAppBlocklist(any())).thenAnswer((_) async {});
    when(() => engineRepo.pushProtectedApps(any())).thenAnswer((_) async {});
    sl
      ..registerSingleton<EngineRepository>(engineRepo)
      ..registerSingleton<WebBlockRepository>(webBlocks)
      ..registerSingleton<AppBlockRepository>(appBlocks)
      ..registerSingleton<SettingsRepository>(settingsRepo)
      ..registerSingleton<ProtectedAppsRepository>(protectedApps);
    addTearDown(sl.reset);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: providers(),
        child: const AppResumeSync(
          heavyLegInterval: Duration.zero,
          child: SizedBox(),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    verify(() => targets.load()).called(1);
    verify(() => engineRepo.pushWebBlocklist(any())).called(1);
    verify(() => engineRepo.pushAppBlocklist(any())).called(1);
    verify(() => engineRepo.pushProtectedApps(any())).called(1);
  });

  testWidgets('non-resume transitions do nothing', (tester) async {
    await pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    verifyNever(() => permissions.refresh());
    verifyNever(() => settings.resync());
  });
}
