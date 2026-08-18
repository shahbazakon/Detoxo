import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_cubit.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The website blocker's batch protections, split out of the main screen:
/// each toggle blocks a whole category of sites at once. Reached from the
/// "Protection" pill on the website-blocker screen.
class WebProtectionScreen extends StatelessWidget {
  const WebProtectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      // Same cubit as the main screen: the toggles live in settings, and both
      // screens re-load on entry, so two instances never drift.
      create: (_) => WebBlockCubit(
        sl<WebBlockRepository>(),
        sl<SettingsRepository>(),
        sl<AppBlockRepository>(),
        sl<WebBlockStatsRepository>(),
        sl<EngineRepository>(),
      )..load(),
      child: const _WebProtectionView(),
    );
  }
}

class _WebProtectionView extends StatelessWidget {
  const _WebProtectionView();

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(
        title: Text('Protection'),
        actions: [
          InfoButton(
            'Batch protections block whole categories of sites at once — no '
            'need to add them one by one. They work in any browser alongside '
            'your blocklist.',
          ),
        ],
      ),
      body: SafeArea(
        child: BlocConsumer<WebBlockCubit, WebBlockState>(
          listenWhen: (p, c) => p.error != c.error && c.error != null,
          listener: (context, state) {
            GlassToast.show(context, state.error!, tone: AppTone.danger);
            context.read<WebBlockCubit>().clearError();
          },
          builder: (context, state) {
            if (state.isLoading) {
              return const LoadingState(message: 'Loading…');
            }
            final cubit = context.read<WebBlockCubit>();
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                Text(
                  'One switch, a whole category of sites.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.glass.onGlassMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppToggleTile(
                  title: 'Block websites of blocked apps',
                  subtitle:
                      'Apps you block stay blocked in the browser too — '
                      'their web versions are closed automatically.',
                  leading: const IconBadge(
                    icon: Icons.apps_outlined,
                    color: AppColors.seed,
                    shape: BoxShape.rectangle,
                  ),
                  value: state.blockForApps,
                  selected: state.blockForApps,
                  onChanged: (v) => cubit.setBlockForApps(value: v),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppToggleTile(
                  title: 'Block adult content (18+)',
                  subtitle:
                      'Blocks known adult sites in any browser, on top of '
                      'your own blocklist.',
                  leading: const IconBadge(
                    icon: Icons.shield_outlined,
                    color: AppColors.danger,
                    shape: BoxShape.rectangle,
                  ),
                  value: state.blockAdult,
                  selected: state.blockAdult,
                  onChanged: (v) => cubit.setBlockAdult(value: v),
                ),
              ],
            ).animate().fadeIn(duration: AppDurations.normal);
          },
        ),
      ),
    );
  }
}
