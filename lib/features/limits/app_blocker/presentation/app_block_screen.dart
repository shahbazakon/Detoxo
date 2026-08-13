import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/widgets/block_app_tile.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/app_blocker/presentation/app_block_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// One place to manage blocking: the curated catalog of built-in feeds/surfaces
/// (install-aware, from [TargetsCubit]/[SettingsCubit]) and custom whole-app
/// locks the user adds ([AppBlockCubit]). The two systems enforce differently —
/// this screen just unifies their management.
class AppBlockScreen extends StatelessWidget {
  const AppBlockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TargetsCubit + SettingsCubit are global (main.dart); only the custom-block
    // cubit is scoped to this route.
    return BlocProvider(
      create: (_) => AppBlockCubit(sl<AppBlockRepository>())..load(),
      child: const _AppBlockView(),
    );
  }
}

class _AppBlockView extends StatefulWidget {
  const _AppBlockView();

  @override
  State<_AppBlockView> createState() => _AppBlockViewState();
}

class _AppBlockViewState extends State<_AppBlockView> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(
        title: Text('Block apps'),
        actions: [
          InfoButton(
            'Two ways to block: switch off a built-in feed (Reels, Shorts, '
            'Explore…) to keep the app but lose the feed, or add an app by its '
            'package name to lock the whole thing.',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAdd(context),
        icon: const Icon(Icons.add),
        label: const Text('Add app'),
      ),
      body: SafeArea(
        child: BlocBuilder<TargetsCubit, TargetsState>(
          builder: (context, targets) {
            final enabledIds = context
                .watch<SettingsCubit>()
                .state
                .enabledPlatformIds;
            final custom = context.watch<AppBlockCubit>().state;

            return ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                // Clear the extended FAB.
                96 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                ..._customSection(context, custom),
                const SizedBox(height: AppSpacing.lg),
                ..._curatedSection(context, targets, enabledIds),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Custom whole-app locks ────────────────────────────────────────────────
  List<Widget> _customSection(
    BuildContext context,
    List<AppBlockEntry> custom,
  ) {
    return [
      const SectionHeader('Custom apps'),
      if (custom.isEmpty)
        const InlineHint(
          icon: Icons.add_circle_outline,
          text: 'No custom apps yet.',
        )
      else
        for (var i = 0; i < custom.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: AppCard(
              title: custom[i].appName,
              subtitle: custom[i].packageName,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppToggle(
                    value: custom[i].enabled,
                    onChanged: (v) =>
                        context.read<AppBlockCubit>().toggle(i, enabled: v),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => context.read<AppBlockCubit>().removeAt(i),
                  ),
                ],
              ),
            ),
          ),
    ];
  }

  // ── Curated, install-aware feeds & surfaces ───────────────────────────────
  List<Widget> _curatedSection(
    BuildContext context,
    TargetsState state,
    Set<String> enabledIds,
  ) {
    if (state.isLoading) {
      return const [
        SectionHeader('Apps & feeds'),
        Padding(
          padding: EdgeInsets.only(top: AppSpacing.md),
          child: LoadingState(message: 'Loading apps…'),
        ),
      ];
    }
    if (state.error != null) {
      return [
        const SectionHeader('Apps & feeds'),
        EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load apps',
          subtitle: state.error,
          action: SecondaryButton(
            label: 'Retry',
            onPressed: () => context.read<TargetsCubit>().load(),
          ),
        ),
      ];
    }

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

    return [
      const SectionHeader('Apps & feeds'),
      if (state.targets.length > 8) ...[
        AppSearchField(
          hintText: 'Search apps & feeds',
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: AppSpacing.md),
      ],
      if (apps.isNotEmpty)
        for (final group in BlockAppGroup.from(apps))
          _appTile(context, group, enabledIds),
      if (browsers.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sm),
        const SectionHeader('Browsers'),
        for (final group in BlockAppGroup.from(browsers))
          _appTile(context, group, enabledIds),
      ],
      if (filtered.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.md),
          child: EmptyState(icon: Icons.search_off, title: 'No matches'),
        ),
    ];
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

  Future<void> _showAdd(BuildContext context) async {
    final cubit = context.read<AppBlockCubit>();
    final pkgController = TextEditingController();
    final nameController = TextEditingController();
    await AppDialog.show<void>(
      context: context,
      title: 'Block an app',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'App name'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: pkgController,
            decoration: const InputDecoration(
              labelText: 'Package (com.example.app)',
            ),
          ),
        ],
      ),
      actions: [
        GhostButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PrimaryButton(
          label: 'Add',
          onPressed: () {
            cubit.add(pkgController.text, nameController.text);
            Navigator.of(context).pop();
          },
        ),
      ],
    );
    pkgController.dispose();
    nameController.dispose();
  }
}
