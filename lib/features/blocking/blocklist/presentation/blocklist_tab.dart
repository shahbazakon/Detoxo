import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/widgets/block_app_tile.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Lists every blockable surface and lets the user toggle each. Every target is
/// free to use — the app has no paid tier.
class BlocklistTab extends StatefulWidget {
  const BlocklistTab({this.scrollController, this.onMenu, super.key});

  final ScrollController? scrollController;

  /// Opens the right-side app drawer (former "More" tab).
  final VoidCallback? onMenu;

  @override
  State<BlocklistTab> createState() => _BlocklistTabState();
}

class _BlocklistTabState extends State<BlocklistTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TargetsCubit, TargetsState>(
      builder: (context, state) {
        if (state.isLoading) {
          return const LoadingState(message: 'Loading blocklist…');
        }
        if (state.error != null) {
          return EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load the blocklist',
            subtitle: state.error,
            action: SecondaryButton(
              label: 'Retry',
              onPressed: () => context.read<TargetsCubit>().load(),
            ),
          );
        }

        final settings = context.watch<SettingsCubit>().state;
        final showSearch = state.targets.length > 8;

        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? state.targets
            : state.targets
                  .where(
                    (t) =>
                        t.displayName.toLowerCase().contains(q) ||
                        t.appName.toLowerCase().contains(q),
                  )
                  .toList();

        final apps = filtered.where((t) => !t.isBrowser).toList();
        final browsers = filtered.where((t) => t.isBrowser).toList();

        return ListView(
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.floatingNavClearance +
                MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'What to block',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                DrawerMenuButton(onTap: widget.onMenu),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Toggle the feeds and surfaces Detoxo should block.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            if (showSearch) ...[
              AppSearchField(
                hintText: 'Search apps & feeds',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (apps.isNotEmpty) ...[
              const _GroupHeader('Apps'),
              for (final group in BlockAppGroup.from(apps))
                _appTile(context, group, settings.enabledPlatformIds),
            ],
            if (browsers.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              const _GroupHeader('Browsers'),
              for (final group in BlockAppGroup.from(browsers))
                _appTile(context, group, settings.enabledPlatformIds),
            ],
            if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xl),
                child: EmptyState(icon: Icons.search_off, title: 'No matches'),
              ),
          ],
        );
      },
    );
  }

  Widget _appTile(
    BuildContext context,
    BlockAppGroup group,
    Set<String> enabledIds,
  ) {
    return BlockAppTile(
      group: group,
      enabledIds: enabledIds,
      onToggle: (id, {required enabled}) =>
          context.read<SettingsCubit>().togglePlatform(id, enabled: enabled),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.xs),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
