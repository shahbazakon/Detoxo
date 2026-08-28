import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/services/firebase/firebase.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/access_protection/data/repositories/pin_repository_impl.dart';
import 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
import 'package:detoxo/features/additional_feature/app_feedback/data/repositories/email_feedback_repository_impl.dart';
import 'package:detoxo/features/additional_feature/app_feedback/domain/repositories/feedback_repository.dart';
import 'package:detoxo/features/additional_feature/app_upgrader/data/repositories/upgrader_app_upgrade_service.dart';
import 'package:detoxo/features/additional_feature/app_upgrader/domain/repositories/app_upgrade_service.dart';
import 'package:detoxo/features/analytics/data/repositories/analytics_repository_impl.dart';
import 'package:detoxo/features/analytics/domain/repositories/analytics_repository.dart';
import 'package:detoxo/features/blocking/plans/data/repositories/content_repository_impl.dart';
import 'package:detoxo/features/blocking/plans/domain/repositories/content_repository.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/config_repository_impl.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/engine_repository_impl.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/settings_repository_impl.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/content_counter/content_counter_bubble/data/repositories/bubble_repository_impl.dart';
import 'package:detoxo/features/content_counter/content_counter_bubble/domain/repositories/bubble_repository.dart';
import 'package:detoxo/features/content_counter/content_counter_core/data/repositories/content_counter_repository_impl.dart';
import 'package:detoxo/features/content_counter/content_counter_core/data/repositories/counter_appearance_repository_impl.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/content_counter_repository.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/counter_appearance_repository.dart';
import 'package:detoxo/features/content_counter/home_content_counter/data/repositories/home_widget_repository_impl.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/repositories/home_widget_repository.dart';
import 'package:detoxo/features/limits/app_blocker/data/repositories/app_block_repository_impl.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/daily_limit/data/repositories/daily_limit_repository_impl.dart';
import 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
import 'package:detoxo/features/limits/streak/data/repositories/streak_repository_impl.dart';
import 'package:detoxo/features/limits/streak/domain/repositories/streak_repository.dart';
import 'package:detoxo/features/limits/web_blocker/data/repositories/web_block_repository_impl.dart';
import 'package:detoxo/features/limits/web_blocker/data/repositories/web_block_stats_repository_impl.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';
import 'package:detoxo/features/permissions/data/repositories/permission_repository_impl.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:detoxo/features/protected_apps/data/repositories/protected_apps_repository_impl.dart';
import 'package:detoxo/features/protected_apps/domain/repositories/protected_apps_repository.dart';
import 'package:get_it/get_it.dart';

/// Service locator. Composition root for the whole app; blocs resolve their
/// dependencies from here (registered as interfaces for testability).
final GetIt sl = GetIt.instance;

Future<void> configureDependencies() async {
  // Infrastructure.
  final store = await LocalStore.create();
  sl
    ..registerSingleton<LocalStore>(store)
    ..registerLazySingleton<EngineChannel>(EngineChannel.new)
    // Firebase telemetry (analytics / crashlytics / performance).
    ..registerLazySingleton<CrashReportingService>(
      FirebaseCrashReportingService.new,
    )
    ..registerLazySingleton<AnalyticsService>(FirebaseAnalyticsService.new)
    ..registerLazySingleton<PerformanceService>(FirebasePerformanceService.new)
    ..registerLazySingleton<FirebaseNativeEventReporter>(
      () => FirebaseNativeEventReporter(sl(), sl(), sl()),
    )
    // Repositories (interface -> implementation).
    ..registerLazySingleton<ConfigRepository>(ConfigRepositoryImpl.new)
    ..registerLazySingleton<SettingsRepository>(
      () => SettingsRepositoryImpl(sl()),
    )
    ..registerLazySingleton<EngineRepository>(() => EngineRepositoryImpl(sl()))
    ..registerLazySingleton<PermissionRepository>(
      () => PermissionRepositoryImpl(sl(), sl()),
    )
    ..registerLazySingleton<PinRepository>(() => PinRepositoryImpl(sl(), sl()))
    ..registerLazySingleton<WebBlockRepository>(
      () => WebBlockRepositoryImpl(sl()),
    )
    ..registerLazySingleton<WebBlockStatsRepository>(
      () => WebBlockStatsRepositoryImpl(sl(), sl()),
    )
    ..registerLazySingleton<AppBlockRepository>(
      () => AppBlockRepositoryImpl(sl()),
    )
    ..registerLazySingleton<ProtectedAppsRepository>(
      () => ProtectedAppsRepositoryImpl(sl()),
    )
    ..registerLazySingleton<DailyLimitRepository>(
      () => DailyLimitRepositoryImpl(sl()),
    )
    ..registerLazySingleton<StreakRepository>(() => StreakRepositoryImpl(sl()))
    ..registerLazySingleton<AnalyticsRepository>(
      () => AnalyticsRepositoryImpl(sl()),
    )
    ..registerLazySingleton<ContentRepository>(ContentRepositoryImpl.new)
    // Short-video / reel counter.
    ..registerLazySingleton<ContentCounterRepository>(
      () => ContentCounterRepositoryImpl(sl(), sl()),
    )
    ..registerLazySingleton<HomeWidgetRepository>(
      () => HomeWidgetRepositoryImpl(sl()),
    )
    ..registerLazySingleton<BubbleRepository>(() => BubbleRepositoryImpl(sl()))
    ..registerLazySingleton<CounterAppearanceRepository>(
      () => CounterAppearanceRepositoryImpl(sl()),
    )
    // In-app feedback (emails the annotated screenshot to support).
    ..registerLazySingleton<FeedbackRepository>(EmailFeedbackRepositoryImpl.new)
    // App upgrader (Play Store update prompt; Android-only, fails closed).
    ..registerLazySingleton<AppUpgradeService>(UpgraderAppUpgradeService.new);
}
