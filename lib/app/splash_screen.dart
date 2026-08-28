import 'dart:async';

import 'package:detoxo/app/engine_sync.dart';
import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/content_counter_repository.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/repositories/home_widget_repository.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:detoxo/gen/assets.gen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// Boots the app state, then routes to onboarding / PIN lock / permissions /
/// home depending on what the user has already set up.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final settings = context.read<SettingsCubit>();
    final targets = context.read<TargetsCubit>();
    final permissions = context.read<PermissionsCubit>();
    final pin = context.read<PinCubit>();

    // Only what the routing decision below reads. `targets.load()` is the slow
    // leg (native config push + installed-package scan) and nothing here needs
    // it after first run, so it stays off the critical path.
    await Future.wait([
      settings.bootstrap(),
      permissions.refresh(),
      pin.load(),
    ]);

    // First run: seed the enabled set from each installed target's default
    // status — don't pre-enable apps the user doesn't have. Needs the scan.
    if (settings.state.enabledPlatformIds.isEmpty) {
      await targets.load();
      final defaults = targets.state.targets
          .where((t) => t.defaultEnabled && t.isInstalled)
          .map((t) => t.platformId)
          .toSet();
      if (defaults.isNotEmpty) await settings.setEnabledPlatforms(defaults);
    } else {
      unawaited(targets.load());
    }

    // Reel counter runs natively (enabled by default); refresh the home widget
    // with the latest snapshot. Fire-and-forget so it never blocks routing.
    unawaited(_refreshReelCounterWidget());

    // Blocklist drift repair: protected apps, web blocklist and whole-app
    // blocks all pushed so the native engine matches Dart without any screen
    // ever being opened. Fire-and-forget so it never blocks routing.
    unawaited(syncEngineBlocklists());

    if (!mounted) return;

    if (!settings.state.onboarded) {
      context.go(Routes.onboarding);
      return;
    }
    if (pin.state.isConfigured && pin.state.guards(PinScope.app)) {
      context.go(Routes.pinLock);
      return;
    }
    if (!permissions.allRequiredGranted) {
      context.go(Routes.permissions);
      return;
    }
    context.go(Routes.home);
  }

  /// Pushes the current counter snapshot to the home-screen widget on launch.
  Future<void> _refreshReelCounterWidget() async {
    final count = await sl<ContentCounterRepository>().current();
    await sl<HomeWidgetRepository>().pushSnapshot(count);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassScaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: AppShadows.glowIndigo,
                  ),
                  child: Image.asset(
                    Assets.images.detoxLogoNoBg.path,
                    width: 120,
                    height: 120,
                    fit: BoxFit.contain,
                  ),
                )
                .animate()
                .fadeIn(duration: AppDurations.fast)
                .scaleXY(begin: 0.85, end: 1, curve: Curves.easeOutBack),
            const SizedBox(height: AppSpacing.xl),
            Text(
                  'Detoxo',
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                )
                .animate()
                .fadeIn(
                  delay: AppDurations.stagger,
                  duration: AppDurations.fast,
                )
                .slideY(begin: 0.2, end: 0),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Reclaim your attention',
              style: text.bodyMedium,
            ).animate().fadeIn(
              delay: AppDurations.stagger * 2,
              duration: AppDurations.fast,
            ),
            const SizedBox(height: AppSpacing.xxl),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ).animate().fadeIn(delay: AppDurations.stagger * 3),
          ],
        ),
      ),
    );
  }
}
