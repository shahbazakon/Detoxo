import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/utils/clock_format.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/rule_summary.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
import 'package:detoxo/features/limits/unblock/presentation/widgets/unblock_duration_sheet.dart';
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
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

/// Manage website blocking: one-tap popular-site chips (led by a Protection
/// pill that opens the batch-protection screen), a searchable custom
/// blocklist, and a stats dashboard. Enforcement runs natively by reading the
/// browser address bar and pressing back on a blocked domain.
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
            'Blocks distracting sites in any supported browser — Detoxo reads '
            'the address bar and backs you out of the page. Tap a popular '
            'site, add your own, or open Protection to block whole categories.',
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
                inset(const SectionHeader('Popular sites')),
                _PopularChips(state: state),
                inset(
                  SectionHeader(
                    state.hasEntries
                        ? 'Your blocklist (${state.entries.length})'
                        : 'Your blocklist',
                  ),
                ),
                inset(_Blocklist(state: state)),
                if (state.unsupportedBrowsers.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  inset(
                    _UnsupportedBrowsersNotice(
                      browsers: state.unsupportedBrowsers,
                    ),
                  ),
                ],
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

// ── Unsupported browsers (EVO-047) ──────────────────────────────────────────
/// Names the installed browsers the engine cannot read, so the screen never
/// looks protective about a browser where nothing is enforced. Only rendered
/// when native actually answered and the list is non-empty — silence means
/// "all covered" or "couldn't ask", and inventing a warning for the second
/// would be its own kind of lie.
class _UnsupportedBrowsersNotice extends StatelessWidget {
  const _UnsupportedBrowsersNotice({required this.browsers});

  final List<String> browsers;

  @override
  Widget build(BuildContext context) {
    final names = browsers.join(', ');
    return Semantics(
      label: 'Not covered: $names. Blocking does not apply in these browsers.',
      excludeSemantics: true,
      child: AppCard(
        leading: const IconBadge(
          icon: Icons.warning_amber_outlined,
          color: AppColors.warning,
          shape: BoxShape.rectangle,
        ),
        title: 'Not covered: $names',
        subtitle:
            "Detoxo can't read the address bar in "
            '${browsers.length == 1 ? 'this browser' : 'these browsers'}, so '
            'your blocklist and the 18+ filter do not apply there.',
      ),
    );
  }
}

// ── Protection pill: batch protections live on their own screen ─────────────
/// Leads the popular-sites row but is deliberately not an [AppChip]: it is
/// always seed-tinted with a trailing chevron so it reads as "opens a screen",
/// not "toggles a site". Shows how many batch protections are on.
class _ProtectionChip extends StatelessWidget {
  const _ProtectionChip({required this.activeCount});

  final int activeCount;

  @override
  Widget build(BuildContext context) {
    const seed = AppColors.seed;
    Future<void> open() async {
      final cubit = context.read<WebBlockCubit>();
      await context.push<void>(Routes.webProtection);
      // The sub-screen edits the same persisted settings; re-load so this
      // pill's count is fresh when the user comes back.
      await cubit.load();
    }

    return Semantics(
      label:
          'Protection, $activeCount of ${WebBlockState.protectionTotal} on, '
          'opens screen',
      button: true,
      excludeSemantics: true,
      child: AppPressable(
        onTap: open,
        pressedScale: 0.94,
        minTapTarget: const Size(0, AppSizes.minTapTarget),
        child: GlassContainer(
          enableBlur: false,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          borderRadius: AppRadius.pill,
          tintTop: seed.withValues(alpha: 0.30),
          tintBottom: seed.withValues(alpha: 0.14),
          borderColor: seed.withValues(alpha: 0.6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: seed),
              const SizedBox(width: AppSpacing.xxs),
              Text(
                activeCount > 0 ? 'Protection · $activeCount' : 'Protection',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: AppSpacing.xxs),
              const Icon(Icons.chevron_right, size: 16),
            ],
          ),
        ),
      ),
    );
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
    // Two rows sharing one horizontal scroll; the Protection pill opens the
    // first row and the "Add website" chip closes the second, so each row
    // carries one extra chip and the split is an even half.
    final half = sites.length ~/ 2;
    final protectionCount = state.protectionCount;
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
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.xs),
                child: _ProtectionChip(activeCount: protectionCount),
              ),
              for (final site in sites.take(half)) chip(site),
            ],
          ),
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
    if (state.loadFailed) {
      // Unreadable, NOT empty: offering "add your own" here would invite the
      // user to type over a list that still exists and is still being
      // enforced natively. Retry, and say what actually happened.
      return EmptyState(
        icon: Icons.error_outline,
        title: "Couldn't open your blocklist",
        subtitle:
            'Your saved sites are still blocked. Try again, or reopen this '
            'screen.',
        action: PrimaryButton(label: 'Try again', onPressed: cubit.load),
      );
    }
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
          // Only one swipe pane open at a time across the list.
          SlidableAutoCloseBehavior(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _BlocklistRow(entry: entry),
                  ),
              ],
            ),
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
    final color = entry.brandColor != null
        ? Color(entry.brandColor!)
        : Theme.of(context).colorScheme.secondary;
    // M8: the pause window is a grant now, so it comes from UnblockCubit's
    // DERIVED `active` list rather than from `DateTime.now()` at build time.
    // That matters: a cubit emit when the grant lapses actually rebuilds this
    // row, where a build-time clock read left a dead "Paused until 14:05" pill
    // on screen until something unrelated happened.
    final grant = context.select<UnblockCubit, TemporaryUnblock?>(
      (c) => c.state.activeFor(
        UnblockTargetType.website,
        entry.pattern,
        DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final paused = grant != null;
    // Device 12/24-hour preference, like every other time the app reads back
    // (the window is picked in this app's own sheet).
    // "Until 10:30 PM", not "Allowed until …": Pill caps itself at 0.4x screen
    // width, and the longer label ellipsised away the only datum it carries at
    // ordinary text scale. `RuleSummary.clock` adds the weekday when the window
    // ends tomorrow, which a bare clock silently dropped.
    String pausedLabel() =>
        'Until '
        '${RuleSummary.clock(grant!.endMs, DateTime.now(), time: (m) => formatLocalTime(context, m))}';

    // How many actions the pane holds decides how far it opens.
    final actionCount = 1 + (entry.enabled ? 1 : 0) + (isCustom ? 1 : 0);
    // Disabled and paused rows read at a glance via a dimmed badge.
    final dimmed = paused || !entry.enabled;
    // No outer clip: Slidable clips its own pane to the drag ratio, and each
    // action carries its own rounded surface.
    return Slidable(
      key: ValueKey(entry.pattern),
      groupTag: 'web-blocklist',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        // Per-action gaps need a bit more room than the old edge-to-edge
        // pane; keeps every inner surface >= 48dp wide on a 360dp screen.
        extentRatio: const [0.30, 0.52, 0.70][actionCount - 1],
        children: [
          if (entry.enabled)
            _RowAction(
              icon: paused ? Icons.play_arrow : Icons.timer_outlined,
              label: paused ? 'Resume' : 'Allow',
              tone: AppColors.warning,
              semanticLabel: paused
                  ? 'Resume blocking ${entry.label}'
                  : 'Allow ${entry.label} for a while',
              onPressed: (context) => paused
                  ? context.read<UnblockCubit>().endEarly(
                      UnblockTargetType.website,
                      entry.pattern,
                      // The same aliases the grant freed — see `_showAllowSheet`.
                      alsoEnd: entry.source == WebBlockSource.popular
                          ? PopularSites.aliasesFor(entry.pattern)
                          : const [],
                    )
                  : _showAllowSheet(context, entry),
            ),
          if (isCustom)
            _RowAction(
              icon: Icons.edit_outlined,
              label: 'Edit',
              tone: AppColors.seed,
              semanticLabel: 'Edit ${entry.label}',
              onPressed: (context) => _showSiteSheet(context, entry: entry),
            ),
          _RowAction(
            icon: Icons.delete_outline,
            label: 'Delete',
            tone: AppColors.danger,
            semanticLabel: 'Remove ${entry.label}',
            onPressed: (_) => cubit.removeEntry(entry),
          ),
        ],
      ),
      child: Builder(
        // The swipe pane is the only route to Pause/Edit/Delete, and a screen
        // reader cannot swipe. Tap opens the same pane, so the tap target has
        // to SAY that — otherwise TalkBack announces a bare "example.com,
        // button" and those actions are unreachable.
        builder: (rowContext) => MergeSemantics(
          child: Semantics(
            hint: 'Opens allow, edit and delete actions',
            child: AppCard(
              // Tap toggles the pane: swipe discoverability + a non-swipe path.
              onTap: () {
                final slidable = Slidable.of(rowContext);
                if (slidable == null) return;
                if (slidable.ratio == 0) {
                  slidable.openEndActionPane();
                } else {
                  slidable.close();
                }
              },
              leading: AnimatedOpacity(
                opacity: dimmed ? 0.45 : 1,
                duration: AppDurations.fast,
                child: IconBadge(
                  icon: site?.icon ?? Icons.public,
                  color: color,
                  shape: BoxShape.rectangle,
                  fillAlpha: 0.18,
                ),
              ),
              title: entry.label,
              // Popular rows show the domain under the brand name; custom rows'
              // title already IS the domain. Pause gets its own pill below.
              subtitle: isCustom ? null : entry.pattern,
              trailing: AppToggle(
                value: entry.enabled,
                semanticLabel: 'Block ${entry.label}',
                onChanged: (v) => cubit.toggleEntry(entry, enabled: v),
              ),
              // Row keeps the Pill intrinsic-width in AppCard's stretch column.
              child: paused
                  ? Row(
                      children: [
                        Pill(
                          label: pausedLabel(),
                          tone: AppTone.warning,
                          icon: Icons.timer_outlined,
                        ),
                      ],
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// One swipe action as its own rounded surface — same radius as the row card,
/// separated by a small gap so the pane reads as sibling cards.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.label,
    required this.tone,
    required this.semanticLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final String semanticLabel;
  final void Function(BuildContext) onPressed;

  @override
  Widget build(BuildContext context) {
    return CustomSlidableAction(
      onPressed: onPressed,
      backgroundColor: Colors.transparent,
      foregroundColor: tone,
      // The gap between the row card / previous action and this surface.
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      // Press overlay tracks the rounded shape.
      borderRadius: AppRadius.brLg,
      child: Semantics(
        label: semanticLabel,
        button: true,
        excludeSemantics: true,
        // Fill the pane height so the surface matches the row card height.
        child: SizedBox.expand(
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: tone.withValues(alpha: 0.18),
              shape: AppRadius.continuous(
                AppRadius.lg,
                side: BorderSide(color: tone.withValues(alpha: 0.35)),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: tone),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// EVO-012, generalised by M8: pick how long to allow the site. The chips are
/// now the shared `showUnblockDurationSheet` — the same sheet an app row and
/// the block screen use — and the window is a `WEBSITE` grant rather than a
/// per-entry field. Native still re-arms the block at expiry with Detoxo
/// closed; that is the property the whole mechanism exists for.
Future<void> _showAllowSheet(BuildContext context, WebBlockEntry entry) async {
  final unblock = context.read<UnblockCubit>();
  final window = await showUnblockDurationSheet(
    context,
    label: entry.label,
    remaining: unblock.state.grantsLeft,
  );
  if (window == null) return;
  // A popular entry's cross-registrable aliases (youtu.be for youtube.com) ride
  // the wire as their own patterns, so they need their own grants — exactly
  // what `pausedUntil` did when it was duplicated onto them.
  final ok = await unblock.grant(
    UnblockTargetType.website,
    entry.pattern,
    window,
    source: UnblockSource.blocklistRow,
    alsoFree: entry.source == WebBlockSource.popular
        ? PopularSites.aliasesFor(entry.pattern)
        : const [],
  );
  // Only on success — a failure is toasted app-wide by the unblock listener.
  if (ok && context.mounted) {
    GlassToast.show(
      context,
      '${entry.label} allowed for ${window.inMinutes} min',
      tone: AppTone.success,
    );
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
