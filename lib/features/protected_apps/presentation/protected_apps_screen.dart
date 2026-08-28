import 'dart:typed_data';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/widgets/app_picker_sheet.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/access_protection/access_protection.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app_catalog.dart';
import 'package:detoxo/features/protected_apps/domain/repositories/protected_apps_repository.dart';
import 'package:detoxo/features/protected_apps/presentation/protected_apps_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Settings → Privacy → Protected apps: the apps Detoxo completely ignores
/// (banking, UPI, password managers…). Well-known sensitive apps are protected
/// automatically and permanently; the user can only add more.
class ProtectedAppsScreen extends StatelessWidget {
  const ProtectedAppsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ProtectedAppsCubit(
        sl<ProtectedAppsRepository>(),
        sl<EngineRepository>(),
        sl<ConfigRepository>(),
      )..load(),
      child: const _ProtectedAppsView(),
    );
  }
}

class _ProtectedAppsView extends StatefulWidget {
  const _ProtectedAppsView();

  @override
  State<_ProtectedAppsView> createState() => _ProtectedAppsViewState();
}

class _ProtectedAppsViewState extends State<_ProtectedAppsView> {
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
    return BlocBuilder<ProtectedAppsCubit, ProtectedAppsState>(
      builder: (context, state) {
        // Adds are gated until a load succeeds: adding over a failed load
        // would overwrite stored protections, and the PIN gate's monitored
        // set would be empty (it fails closed, but don't rely on it).
        final ready = !state.isLoading && state.error == null;
        return GlassScaffold(
          appBar: const GlassAppBar(
            title: Text('Protected apps'),
            actions: [
              InfoButton(
                'Detoxo automatically pauses all monitoring while you use '
                'these apps. They are never read, counted, blocked or '
                'interrupted.',
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: ready ? () => _showAdd(context) : null,
            icon: const Icon(Icons.add),
            label: const Text('Add app'),
          ),
          body: SafeArea(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                // Clear the extended FAB.
                96 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: _sections(context, state),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _sections(BuildContext context, ProtectedAppsState state) {
    if (state.isLoading) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: AppSpacing.md),
          child: LoadingState(message: 'Loading apps…'),
        ),
      ];
    }
    if (state.error != null) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load protected apps',
            subtitle: state.error,
            action: SecondaryButton(
              label: 'Retry',
              onPressed: () => context.read<ProtectedAppsCubit>().load(),
            ),
          ),
        ),
      ];
    }

    final q = _query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    bool matches(ProtectedApp a) =>
        !searching ||
        a.appName.toLowerCase().contains(q) ||
        a.packageName.toLowerCase().contains(q);

    final auto = state.autoProtected.where(matches).toList();
    final manual = state.apps.where(matches).toList();

    return [
      const InlineHint(
        icon: Icons.verified_user_outlined,
        text:
            'Your protected apps are never interrupted — Detoxo pauses '
            'itself while you use them and resumes when you leave.',
      ),
      const SizedBox(height: AppSpacing.sm),
      if (state.autoProtected.length + state.apps.length > 8) ...[
        AppSearchField(
          hintText: 'Search protected apps',
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: AppSpacing.md),
      ],
      // While searching, empty sections disappear entirely (no bare headers,
      // no onboarding hints competing with "No matches").
      if (!searching || manual.isNotEmpty) ...[
        const SectionHeader('Your apps'),
        if (manual.isEmpty)
          const InlineHint(
            icon: Icons.add_circle_outline,
            text:
                'Apps you add are protected too. Well-known sensitive apps '
                'below are covered already.',
          )
        else
          for (final app in manual)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _manualCard(context, app),
            ),
        const SizedBox(height: AppSpacing.sm),
      ],
      if (!searching || auto.isNotEmpty) ...[
        const SectionHeader('Auto-protected'),
        if (!searching)
          const InlineHint(
            icon: Icons.shield_outlined,
            text:
                'Protected automatically — always on. Banking, payment, '
                'identity and password apps are covered the moment they are '
                'installed.',
          ),
        for (final app in auto)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _autoCard(app),
          ),
      ],
      if (searching && auto.isEmpty && manual.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.md),
          child: EmptyState(icon: Icons.search_off, title: 'No matches'),
        ),
    ];
  }

  /// A user-added entry: deletable, nothing else.
  Widget _manualCard(BuildContext context, ProtectedApp app) {
    return AppCard(
      leading: AppIconAvatar(
        iconUrl: '',
        iconBytes: _appIcons?[app.packageName],
        appName: app.appName,
      ),
      title: app.appName,
      subtitle: app.packageName,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove ${app.appName}',
        onPressed: () =>
            context.read<ProtectedAppsCubit>().remove(app.packageName),
      ),
    );
  }

  /// A catalog entry: read-only — always protected, no controls.
  Widget _autoCard(ProtectedApp app) {
    return AppCard(
      leading: AppIconAvatar(
        iconUrl: '',
        iconBytes: _appIcons?[app.packageName],
        appName: app.appName,
      ),
      title: app.appName,
      subtitle: app.packageName,
      trailing: const Icon(
        Icons.verified_user_outlined,
        semanticLabel: 'Protected automatically — always on',
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Wrap(
          spacing: AppSpacing.xs,
          children: [Pill(label: app.category.label)],
        ),
      ),
    );
  }

  // ── Add flow ──────────────────────────────────────────────────────────────

  Future<void> _showAdd(BuildContext context) async {
    final cubit = context.read<ProtectedAppsCubit>();
    // An app has one role: custom-blocked apps can't also be protected.
    final blocked = await sl<AppBlockRepository>().load();
    if (!context.mounted) return;
    final picked = await showAppPickerSheet(
      context,
      title: 'Protect an app',
      confirmLabel: 'Protect',
      loadApps: sl<EngineRepository>().installedApps,
      refreshApps: () => sl<EngineRepository>().installedApps(refresh: true),
      unavailable: {
        for (final e in blocked) e.packageName: 'Blocked',
        for (final app in ProtectedAppCatalog.apps)
          app.packageName: 'Auto-protected',
        for (final app in cubit.state.apps) app.packageName: 'Protected',
      },
    );
    if (picked == null || picked.isEmpty || !context.mounted) return;
    // Protecting an app Detoxo can block is a self-bypass of blocking, so it
    // costs the same PIN as turning blocking off — once per batch
    // (needsPinToAdd fails closed on an empty monitored set).
    if (picked.any((a) => cubit.needsPinToAdd(a.packageName)) &&
        !await requirePin(context, PinScope.settings)) {
      return;
    }
    final results = <ProtectedAddResult>[
      for (final app in picked)
        await cubit.addManual(app.packageName, app.appName),
    ];
    if (!context.mounted) return;
    _showAddOutcome(context, picked, results);
  }

  /// The toast tells the truth: "Protected" only counts adds that landed, and
  /// a batch where nothing landed says why instead of celebrating a no-op.
  void _showAddOutcome(
    BuildContext context,
    List<InstalledApp> picked,
    List<ProtectedAddResult> results,
  ) {
    final added = results.where((r) => r == ProtectedAddResult.added).length;
    if (added > 0) {
      GlassToast.show(
        context,
        added == picked.length
            ? (added == 1
                  ? 'Protected ${picked.first.appName}'
                  : 'Protected $added apps')
            : 'Protected $added of ${picked.length} apps',
        tone: AppTone.success,
      );
      return;
    }
    final message = switch (results.first) {
      ProtectedAddResult.alreadyCovered => 'Already protected automatically.',
      ProtectedAddResult.duplicate => 'Already protected.',
      _ => 'That doesn’t look like a package id.',
    };
    GlassToast.show(context, message, tone: AppTone.warning);
  }
}
