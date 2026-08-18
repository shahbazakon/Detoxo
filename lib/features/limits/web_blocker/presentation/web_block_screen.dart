import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/popular_site.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_source.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_stats.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/utils/domain_validator.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_cubit.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Manage website blocking: two protection toggles (block the web versions of
/// blocked apps, block adult sites), one-tap popular-site chips, a searchable
/// custom blocklist, and a stats dashboard. Enforcement runs natively by
/// reading the browser address bar and pressing back on a blocked domain.
class WebBlockScreen extends StatelessWidget {
  const WebBlockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => WebBlockCubit(
        sl<WebBlockRepository>(),
        sl<SettingsRepository>(),
        sl<AppBlockRepository>(),
        sl<WebBlockStatsRepository>(),
        sl<EngineRepository>(),
      )..load(),
      child: const _WebBlockView(),
    );
  }
}

class _WebBlockView extends StatelessWidget {
  const _WebBlockView();

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(
        title: Text('Website blocker'),
        actions: [
          InfoButton(
            'Blocks distracting sites in any browser — Detoxo reads the '
            'address bar and closes the tab. Turn on a category, tap a '
            'popular site, or add your own.',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showSiteSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Add website'),
      ),
      body: SafeArea(
        child: BlocConsumer<WebBlockCubit, WebBlockState>(
          listenWhen: (p, c) => p.error != c.error && c.error != null,
          listener: (context, state) {
            GlassToast.show(context, state.error!, tone: AppTone.danger);
            context.read<WebBlockCubit>().clearError();
          },
          // No buildWhen: stats events are rare while this screen is visible
          // (blocks happen while the user is in the browser), so the full
          // rebuild is the cheap option over selector plumbing.
          builder: (context, state) {
            if (state.isLoading) {
              return const LoadingState(message: 'Loading…');
            }
            // The list has no right padding so the chip rows can scroll off the
            // screen edge; every other child adds it back.
            Widget inset(Widget child) => Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: child,
            );
            return ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                0,
                96 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                if (state.hasStats) ...[
                  inset(_StatsSection(stats: state.stats)),
                  const SizedBox(height: AppSpacing.xs),
                ],
                inset(const SectionHeader('Protection')),
                inset(_ProtectionTiles(state: state)),
                inset(const SectionHeader('Popular sites')),
                _PopularChips(state: state),
                inset(const SectionHeader('Your blocklist')),
                inset(_Blocklist(state: state)),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Add / edit sheet, shared by the FAB, the "Add website" chip and row edit.
Future<void> _showSiteSheet(
  BuildContext context, {
  WebBlockEntry? entry,
}) async {
  final cubit = context.read<WebBlockCubit>();
  final host = await GlassBottomSheet.show<String>(
    context: context,
    title: entry == null ? 'Block a website' : 'Edit website',
    child: _SiteSheet(cubit: cubit, entry: entry),
  );
  if (host != null && context.mounted) {
    GlassToast.show(
      context,
      entry == null ? 'Blocked $host' : 'Updated to $host',
      tone: AppTone.success,
    );
  }
}

// ── Stats dashboard ─────────────────────────────────────────────────────────
class _StatsSection extends StatelessWidget {
  const _StatsSection({required this.stats});

  final WebBlockStats stats;

  @override
  Widget build(BuildContext context) {
    return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No `crossAxisAlignment: stretch` here: this Row sits in a
            // ListView, so its height is unbounded — stretch hands the cards
            // an infinite height constraint and layout aborts the frame
            // (blank body, then per-frame `!semantics.parentDataDirty` spam).
            // The three cards are identical, so they match heights anyway.
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    label: 'Blocked today',
                    value: stats.blockedToday,
                    icon: Icons.block,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: StatCard(
                    label: 'Total blocked',
                    value: stats.totalBlocked,
                    icon: Icons.public_off,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: StatCard(
                    label: 'Focus saved',
                    value: stats.focusMinutesSaved,
                    unit: 'min',
                    icon: Icons.timer_outlined,
                  ),
                ),
              ],
            ),
            if (stats.mostBlockedHost != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Icon(
                    Icons.trending_up,
                    size: 16,
                    color: context.glass.onGlassMuted,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Most blocked: ',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.glass.onGlassMuted,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      stats.mostBlockedHost!,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        )
        .animate()
        .fadeIn(duration: AppDurations.normal)
        .slideY(begin: 0.05, end: 0, curve: AppCurves.standard);
  }
}

// ── The two protection toggle tiles ─────────────────────────────────────────
class _ProtectionTiles extends StatelessWidget {
  const _ProtectionTiles({required this.state});

  final WebBlockState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WebBlockCubit>();
    return Column(
      children: [
        AppToggleTile(
          title: 'Block websites of blocked apps',
          leading: const IconBadge(
            icon: Icons.apps_outlined,
            color: AppColors.seed,
            shape: BoxShape.rectangle,
          ),
          value: state.blockForApps,
          onChanged: (v) => cubit.setBlockForApps(value: v),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppToggleTile(
          title: 'Block adult content (18+)',
          leading: const IconBadge(
            icon: Icons.shield_outlined,
            color: AppColors.danger,
            shape: BoxShape.rectangle,
          ),
          value: state.blockAdult,
          onChanged: (v) => cubit.setBlockAdult(value: v),
        ),
      ],
    ).animate().fadeIn(duration: AppDurations.normal);
  }
}

// ── Popular site chips ──────────────────────────────────────────────────────
class _PopularChips extends StatelessWidget {
  const _PopularChips({required this.state});

  final WebBlockState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WebBlockCubit>();
    final active = state.activePopularIds;
    final sites = state.popular;
    // Two rows sharing one horizontal scroll; the "Add website" chip closes
    // the second row so it sits at the end of the scroll.
    final half = (sites.length + 1) ~/ 2;
    Widget chip(PopularSite site) => Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: AppChip(
        label: site.name,
        icon: site.icon,
        selected: active.contains(site.id),
        onSelected: () => cubit.togglePopular(site),
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Only the far end of the scroll keeps a gutter.
      padding: const EdgeInsets.only(right: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [for (final site in sites.take(half)) chip(site)]),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              for (final site in sites.skip(half)) chip(site),
              AppChip(
                label: 'Add website',
                icon: Icons.add,
                selected: false,
                onSelected: () => _showSiteSheet(context),
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: AppDurations.normal);
  }
}

// ── Custom blocklist (search + rows) ────────────────────────────────────────
class _Blocklist extends StatelessWidget {
  const _Blocklist({required this.state});

  final WebBlockState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WebBlockCubit>();
    if (!state.hasEntries) {
      // Same idiom as sibling screens: primary empty list = EmptyState + CTA.
      return EmptyState(
        icon: Icons.public_off,
        title: 'No sites blocked yet',
        subtitle: 'Tap a popular site above or add your own.',
        action: PrimaryButton(
          label: 'Add website',
          onPressed: () => _showSiteSheet(context),
        ),
      );
    }
    final entries = state.visibleEntries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The query keeps the field visible even when deletions shrink the
        // list below the threshold — otherwise an active filter would have no
        // affordance to clear it. Threshold 8 matches the sibling screens.
        if (state.entries.length > 8 || state.query.isNotEmpty) ...[
          AppSearchField(
            hintText: 'Search blocked sites',
            onChanged: cubit.search,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.sm),
            child: EmptyState(icon: Icons.search_off, title: 'No matches'),
          )
        else
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _BlocklistRow(entry: entry),
            ),
      ],
    );
  }
}

class _BlocklistRow extends StatelessWidget {
  const _BlocklistRow({required this.entry});

  final WebBlockEntry entry;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WebBlockCubit>();
    final isCustom = entry.source == WebBlockSource.custom;
    final site = PopularSites.byPrimaryDomain(entry.pattern);
    final paused = entry.isPausedAt(DateTime.now());
    final color = entry.brandColor != null
        ? Color(entry.brandColor!)
        : Theme.of(context).colorScheme.secondary;
    String pausedLabel() {
      final t = entry.pausedUntil!;
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return 'Paused until $h:$m';
    }

    return AppCard(
      leading: IconBadge(
        icon: site?.icon ?? Icons.public,
        color: color,
        shape: BoxShape.rectangle,
        fillAlpha: 0.18,
      ),
      title: entry.label,
      // Popular rows show the domain under the brand name; custom rows' title
      // already IS the domain, so their second line is the pause state or none.
      subtitle: paused ? pausedLabel() : (isCustom ? null : entry.pattern),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppToggle(
            value: entry.enabled,
            semanticLabel: 'Block ${entry.label}',
            onChanged: (v) => cubit.toggleEntry(entry, enabled: v),
          ),
          if (entry.enabled)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(paused ? Icons.play_arrow : Icons.timer_outlined),
              tooltip: paused
                  ? 'Resume blocking ${entry.label}'
                  : 'Pause blocking ${entry.label}',
              onPressed: () => paused
                  ? cubit.resumeEntry(entry)
                  : _showPauseSheet(context, entry),
            ),
          if (isCustom)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit ${entry.label}',
              onPressed: () => _showSiteSheet(context, entry: entry),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove ${entry.label}',
            onPressed: () => cubit.removeEntry(entry),
          ),
        ],
      ),
    );
  }
}

/// EVO-012: pick how long to allow the site; native re-arms the block at
/// expiry even if the app never reopens.
Future<void> _showPauseSheet(BuildContext context, WebBlockEntry entry) async {
  final cubit = context.read<WebBlockCubit>();
  final minutes = await GlassBottomSheet.show<int>(
    context: context,
    title: 'Allow ${entry.label} for…',
    child: Builder(
      builder: (sheetContext) => Wrap(
        spacing: AppSpacing.xs,
        children: [
          for (final m in const [5, 15, 30, 60])
            AppChip(
              label: '$m min',
              selected: false,
              onSelected: () => Navigator.of(sheetContext).pop(m),
            ),
        ],
      ),
    ),
  );
  if (minutes != null) {
    await cubit.pauseEntry(entry, Duration(minutes: minutes));
    if (context.mounted) {
      GlassToast.show(
        context,
        '${entry.label} allowed for $minutes min',
        tone: AppTone.success,
      );
    }
  }
}

/// Add / edit bottom-sheet body with inline domain validation.
class _SiteSheet extends StatefulWidget {
  const _SiteSheet({required this.cubit, this.entry});

  final WebBlockCubit cubit;
  final WebBlockEntry? entry;

  @override
  State<_SiteSheet> createState() => _SiteSheetState();
}

class _SiteSheetState extends State<_SiteSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.entry?.pattern ?? '',
  );
  String? _error;

  bool get _isEdit => widget.entry != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Same rule the cubit enforces — one shared helper, no drifting copies.
    final checked = DomainValidator.check(
      _controller.text,
      widget.cubit.state.entries.map((e) => e.pattern),
      ignoring: widget.entry?.pattern,
    );
    if (checked.host == null) {
      setState(() => _error = checked.error);
      return;
    }
    // Await the commit: success is only announced once persist + push ran.
    final ok = _isEdit
        ? await widget.cubit.editEntry(widget.entry!, _controller.text)
        : await widget.cubit.addCustom(_controller.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(checked.host);
    } else {
      // The cubit surfaced the reason via the screen's error toast.
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(
            hintText: 'e.g. youtube.com',
            errorText: _error,
            prefixIcon: const Icon(Icons.public),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          label: _isEdit ? 'Save' : 'Block website',
          onPressed: _submit,
          expand: true,
        ),
      ],
    );
  }
}
