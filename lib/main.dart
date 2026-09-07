import 'dart:async';

import 'package:detoxo/app/app_resume_sync.dart';
import 'package:detoxo/app/engine_sync.dart';
import 'package:detoxo/app/starter_rule_sync.dart';
import 'package:detoxo/core/design_system/foundations/ambient_background.dart';
import 'package:detoxo/core/design_system/foundations/background_scope.dart';
import 'package:detoxo/core/design_system/foundations/motion.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/app_gate.dart';
import 'package:detoxo/core/navigation/app_router.dart';
import 'package:detoxo/core/services/firebase/firebase.dart';
import 'package:detoxo/core/theme/app_theme.dart';
import 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
import 'package:detoxo/features/access_protection/presentation/pin_auto_relock.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/additional_feature/app_feedback/app_feedback.dart';
import 'package:detoxo/features/analytics/analytics.dart';
import 'package:detoxo/features/blocking/block_screen/domain/repositories/block_screen_repository.dart';
import 'package:detoxo/features/blocking/block_screen/presentation/block_screen_style_cubit.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/engine/presentation/service_cubit.dart';
import 'package:detoxo/features/blocking/plans/presentation/conscious_cubit.dart';
import 'package:detoxo/features/blocking/plans/presentation/reel_session_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/limits/daily_limit/domain/entities/daily_limit.dart';
import 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
import 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_cubit.dart';
import 'package:detoxo/features/limits/rules/domain/repositories/rule_repository.dart';
import 'package:detoxo/features/limits/rules/presentation/rules_cubit.dart';
import 'package:detoxo/features/limits/streak/domain/repositories/streak_repository.dart';
import 'package:detoxo/features/limits/streak/presentation/streak_cubit.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
import 'package:detoxo/features/limits/unblock/presentation/widgets/pending_unblock_listener.dart';
import 'package:detoxo/features/permissions/permissions.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:detoxo/firebase_options.dart';
import 'package:feedback/feedback.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Telemetry init is best-effort: no offline-first app should fail to launch
  // because a Firebase handshake did not come back. DI is NOT in that bucket —
  // without it there is no app to show, so it stays outside the guard.
  await guardedSync(
    'firebase',
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
  );
  // Route uncaught framework and async errors to Crashlytics as early as
  // possible (before DI), so init-time crashes are captured.
  FirebaseCrashReportingService.installGlobalHandlers();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  await configureDependencies();
  // Telemetry: capture cubit events/errors globally, then switch on collection,
  // the anonymous install id and the native-event reporter.
  Bloc.observer = FirebaseBlocObserver(
    sl<AnalyticsService>(),
    sl<CrashReportingService>(),
  );
  await guardedSync('firebaseServices', FirebaseServices.start(sl));
  GlassAppBar.globalActionsBuilder = (_) => const [FeedbackActionButton()];
  runApp(const DetoxoApp());
}

class DetoxoApp extends StatelessWidget {
  const DetoxoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ServiceCubit(sl<EngineRepository>())),
        BlocProvider(create: (_) => ConsciousCubit(sl<EngineRepository>())),
        BlocProvider(create: (_) => ReelSessionCubit(sl<EngineRepository>())),
        BlocProvider(
          create: (_) =>
              SettingsCubit(sl<SettingsRepository>(), sl<EngineRepository>()),
        ),
        BlocProvider(
          create: (_) => TargetsCubit(
            sl<ConfigRepository>(),
            sl<EngineRepository>(),
            performance: sl<PerformanceService>(),
          ),
        ),
        BlocProvider(
          create: (_) => PermissionsCubit(sl<PermissionRepository>()),
        ),
        BlocProvider(create: (_) => PinCubit(sl<PinRepository>())),
        // Live reel-counter stream (today count + today usage time) and the
        // daily limit — both feed the dashboard screen-time ring.
        BlocProvider(
          create: (_) => ContentCounterCubit(
            sl<ContentCounterRepository>(),
            sl<BubbleRepository>(),
          ),
        ),
        // Bubble + widget styling, shared by the Appearance hub and both
        // editors. Lazy: hydrated from native on the first screen that reads it.
        BlocProvider(
          create: (_) =>
              CounterAppearanceCubit(sl<CounterAppearanceRepository>()),
        ),
        // Block-screen style + its on/off switch, shared by the Appearance
        // hub's card and the editor. Lazy: hydrated from native on first read.
        BlocProvider(
          create: (_) => BlockScreenStyleCubit(sl<BlockScreenRepository>()),
        ),
        BlocProvider(
          create: (_) => DailyLimitCubit(sl<DailyLimitRepository>()),
        ),
        // "Days under your daily limit" streak — fed by the dashboard hero and
        // read back into its stat pill.
        BlocProvider(create: (_) => StreakCubit(sl<StreakRepository>())),
        // EVO-058: the Activity tab's screen-time rollups. Lazy, so nothing
        // is computed at boot — the first Activity open constructs it — and
        // app-wide so the tab (rebuilt on every switch) and the drawer route
        // share one instance: a later open paints the last numbers at once
        // and refreshes in place instead of flashing a spinner and running
        // two channel queries per mount. Not `..load()`ed: the view refreshes
        // on mount.
        BlocProvider(
          create: (_) =>
              InsightsCubit(sl<InsightsRepository>(), sl<EngineRepository>()),
        ),
        // Blocking rules (schedules / limits) + THE Dart push path for the
        // native rules snapshot: cold start via `runBootstrap`, resume via
        // AppResumeSync, every edit, and native `ruleBoundary` events.
        // Deliberately NOT `..load()`ed here: bootstrap owns the initial load
        // for this cubit, `DailyLimitCubit` and `StreakCubit`, because it also
        // has to re-run them after an in-process "Reset app data" wipe. Loading
        // in both places ran every one of them twice on every cold start.
        BlocProvider(
          create: (_) => RulesCubit(
            sl<RuleRepository>(),
            sl<DailyLimitRepository>(),
            sl<UsageRepository>(),
            sl<EngineRepository>(),
            ledger: sl<BypassLedgerRepository>(),
          ),
        ),
        // M8: app-wide because four surfaces reach it — the App Blocker and
        // Website blocker rows, the rules screen's override, and the sheet the
        // native wall's "Allow for a while" opens on the next resume.
        BlocProvider(
          create: (_) => UnblockCubit(
            sl<TemporaryUnblockRepository>(),
            sl<BypassLedgerRepository>(),
            sl<EngineRepository>(),
          ),
        ),
      ],
      // The router's gate is fed from here rather than read inside the redirect:
      // cubits are Streams and `refreshListenable` wants a Listenable, and this
      // keeps core/navigation free of feature imports.
      child: MultiBlocListener(
        listeners: [
          BlocListener<SettingsCubit, AppSettings>(
            listenWhen: (a, b) => a.onboarded != b.onboarded,
            listener: (_, s) => sl<AppGate>().update(onboarded: s.onboarded),
          ),
          BlocListener<PermissionsCubit, List<PermissionStatus>>(
            listener: (context, _) => sl<AppGate>().update(
              permissionsOk: context
                  .read<PermissionsCubit>()
                  .allRequiredGranted,
            ),
          ),
        ],
        child: BlocListener<SettingsCubit, AppSettings>(
          listenWhen: (a, b) => a.vibrationEnabled != b.vibrationEnabled,
          listener: (_, state) => AppHaptics.enabled = state.vibrationEnabled,
          // The Daily Limit is enforced through the rules snapshot (its native
          // reel-time meter), so a saved limit re-pushes it.
          child: BlocListener<DailyLimitCubit, DailyLimit>(
            listenWhen: (a, b) => a.limit != b.limit,
            listener: (context, _) =>
                unawaited(context.read<RulesCubit>().resync()),
            child:
                BlocSelector<
                  SettingsCubit,
                  AppSettings,
                  (AppThemeMode, AppBackground, AppBackground)
                >(
                  selector: (s) =>
                      (s.themeMode, s.darkBackground, s.lightBackground),
                  builder: (_, sel) {
                    final darkStyle = _bgStyle(sel.$2);
                    final lightStyle = _bgStyle(sel.$3);
                    return BackgroundScope(
                      dark: darkStyle,
                      light: lightStyle,
                      // The selected background drives the live brand accent so the
                      // whole app harmonises with what's behind the glass.
                      child: _Router(
                        themeMode: _flutterThemeMode(sel.$1),
                        darkBrand: brandFor(darkStyle, Brightness.dark),
                        lightBrand: brandFor(lightStyle, Brightness.light),
                      ),
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }
}

/// Maps the domain appearance preference to a Flutter [ThemeMode].
ThemeMode _flutterThemeMode(AppThemeMode mode) => switch (mode) {
  AppThemeMode.system => ThemeMode.system,
  AppThemeMode.light => ThemeMode.light,
  AppThemeMode.dark => ThemeMode.dark,
};

/// Maps the domain background preference to the design-system style enum.
AppBackgroundStyle _bgStyle(AppBackground background) => switch (background) {
  AppBackground.aurora => AppBackgroundStyle.aurora,
  AppBackground.dark1 => AppBackgroundStyle.dark1,
  AppBackground.dark2 => AppBackgroundStyle.dark2,
  AppBackground.dark3 => AppBackgroundStyle.dark3,
  AppBackground.dark4 => AppBackgroundStyle.dark4,
  AppBackground.dark5 => AppBackgroundStyle.dark5,
  AppBackground.dark6 => AppBackgroundStyle.dark6,
  AppBackground.light1 => AppBackgroundStyle.light1,
  AppBackground.light2 => AppBackgroundStyle.light2,
  AppBackground.light3 => AppBackgroundStyle.light3,
  AppBackground.light4 => AppBackgroundStyle.light4,
  AppBackground.light5 => AppBackgroundStyle.light5,
};

class _Router extends StatefulWidget {
  const _Router({
    required this.themeMode,
    required this.darkBrand,
    required this.lightBrand,
  });

  final ThemeMode themeMode;

  /// Background-matched brand pairing for each theme, fed into [AppTheme] so the
  /// primary/accent adapt to the selected dark/light background.
  final ({Color primary, Color accent}) darkBrand;
  final ({Color primary, Color accent}) lightBrand;

  @override
  State<_Router> createState() => _RouterState();
}

class _RouterState extends State<_Router> {
  final _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return BetterFeedback(
      themeMode: widget.themeMode,
      theme: glassFeedbackTheme(Brightness.light),
      darkTheme: glassFeedbackTheme(Brightness.dark),
      feedbackBuilder: (context, onSubmit, scrollController) =>
          GlassFeedbackForm(
            onSubmit: onSubmit,
            scrollController: scrollController,
          ),
      child: AppResumeSync(
        // Arms the first run's starter rule on the accessibility-grant edge.
        // App-wide so a grant made from anywhere counts, not just from the
        // permission screen.
        child: StarterRuleSync(
          child: PinAutoRelock(
            router: _router,
            child: MaterialApp.router(
              title: 'Detoxo',
              theme: AppTheme.light(
                brandPrimary: widget.lightBrand.primary,
                brandAccent: widget.lightBrand.accent,
              ),
              darkTheme: AppTheme.dark(
                brandPrimary: widget.darkBrand.primary,
                brandAccent: widget.darkBrand.accent,
              ),
              themeMode: widget.themeMode,
              routerConfig: _router,
              debugShowCheckedModeBanner: false,
              // M8: the sheet a wall's "Allow for a while" opens. Mounted
              // here, INSIDE the router, so it can never float over the PIN
              // lock or the splash.
              builder: (context, child) =>
                  PendingUnblockListener(child: child ?? const SizedBox()),
            ),
          ),
        ),
      ),
    );
  }
}
