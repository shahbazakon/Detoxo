import 'package:detoxo/app/bootstrap.dart';
import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/gen/assets.gen.dart';
import 'package:flutter/material.dart';

/// The brand moment shown while [runBootstrap] hydrates the app.
///
/// It no longer routes. Gating moved to the router's single `redirect` (see
/// `AppGate`), which the bootstrap opens by flipping `ready` — so this screen
/// is what the user looks at, and nothing more.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) runBootstrap(context);
    });
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
