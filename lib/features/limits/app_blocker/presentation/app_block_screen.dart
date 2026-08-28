import 'dart:typed_data';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/widgets/app_picker_sheet.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/widgets/block_app_tile.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/limits/app_blocker/domain/app_block_sync.dart';
import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/app_blocker/presentation/app_block_cubit.dart';
import 'package:detoxo/features/limits/web_blocker/domain/web_block_sync.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
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
      create: (_) => AppBlockCubit(
        sl<AppBlockRepository>(),
        // Keep native in step with every mutation: the enforced whole-app
        // blocklist first, then the app-derived web rules.
        onChanged: () async {
          await syncAppBlocklist(sl(), sl());
          await syncWebBlocklist(sl(), sl(), sl(), sl());
        },
      )..load(),
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

  /// Device icons by package, from the engine's cached scan — also pre-warms
  /// the cache so the add-picker opens instantly. Null until loaded; rows fall
  /// back to letter tiles.
  Map<String, Uint8List>? _appIcons;

  @override
  void initState() {
    super.initState();
    sl<EngineRepository>().installedApps().then((apps) {
      if (!mounted || apps == null) return;
      setState(() {
        _appIcons = {for (final a in apps) a.packageName: ?a.icon};
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(
        title: Text('Block apps'),
        actions: [
          InfoButton(
            'Two ways to block: switch off a built-in feed (Reels, Shorts, '
            'Explore…) to keep the app but lose the feed, or pick any app on '
            'your phone to lock the whole thing.',
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
                // No section at all until the first custom app: the FAB is the
                // entry point, and an empty hint would just push the catalog down.
                if (custom.isNotEmpty) ...[
                  ..._customSection(context, custom),
                  const SizedBox(height: AppSpacing.lg),
                ],
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
      for (var i = 0; i < custom.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: AppCard(
            leading: AppIconAvatar(
              iconUrl: '',
              iconBytes: _appIcons?[custom[i].packageName],
              appName: custom[i].appName,
            ),
            title: custom[i].appName,
            subtitle: custom[i].packageName,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppToggle(
                  value: custom[i].enabled,
                  semanticLabel: 'Block ${custom[i].appName}',
                  onChanged: (v) =>
                      context.read<AppBlockCubit>().toggle(i, enabled: v),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove ${custom[i].appName}',
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
    // Protected apps can't be blocked (an app has one role; protection wins
    // natively anyway) — surface that in the picker instead of failing silently.
    final protected = await sl<ProtectedAppsRepository>().load();
    if (!context.mounted) return;
    final picked = await showAppPickerSheet(
      context,
      title: 'Block an app',
      confirmLabel: 'Block',
      loadApps: sl<EngineRepository>().installedApps,
      refreshApps: () => sl<EngineRepository>().installedApps(refresh: true),
      unavailable: {
        for (final e in cubit.state) e.packageName: 'Added',
        for (final a in ProtectedAppCatalog.apps)
          a.packageName: 'Auto-protected',
        for (final a in protected) a.packageName: 'Protected',
      },
    );
    if (picked == null || picked.isEmpty) return;
    final results = <AppBlockAddResult>[
      for (final app in picked) await cubit.add(app.packageName, app.appName),
    ];
    if (!context.mounted) return;
    _showAddOutcome(context, picked, results);
  }

  /// The toast tells the truth: "Added" only counts adds that landed, and a
  /// batch where nothing landed says why instead of celebrating a no-op.
  /// ("Added", not "Blocked": enforcement is native and real, but it engages
  /// on the entry's toggle/sync — this toast reports only the list mutation.)
  void _showAddOutcome(
    BuildContext context,
    List<InstalledApp> picked,
    List<AppBlockAddResult> results,
  ) {
    final added = results.where((r) => r == AppBlockAddResult.added).length;
    if (added > 0) {
      GlassToast.show(
        context,
        added == picked.length
            ? (added == 1
                  ? 'Added ${picked.first.appName}'
                  : 'Added $added apps')
            : 'Added $added of ${picked.length} apps',
        tone: AppTone.success,
      );
      return;
    }
    final message = switch (results.first) {
      AppBlockAddResult.sensitive => 'Sensitive app — Detoxo never blocks it.',
      AppBlockAddResult.duplicate => 'Already in your list.',
      AppBlockAddResult.failed => 'Couldn’t save — try again.',
      _ => 'That doesn’t look like a package id.',
    };
    GlassToast.show(context, message, tone: AppTone.warning);
  }
}
