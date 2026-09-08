import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/utils/clock_format.dart';
import 'package:detoxo/core/widgets/app_picker_sheet.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule_editor_args.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/rule_summary.dart';
import 'package:detoxo/features/limits/rules/presentation/rules_cubit.dart';
import 'package:detoxo/features/limits/rules/presentation/widgets/override_tile.dart';
import 'package:detoxo/features/limits/rules/presentation/widgets/reel_feed_sheet.dart';
import 'package:detoxo/features/limits/rules/presentation/widgets/rule_kind_icon.dart';
import 'package:detoxo/features/limits/rules/presentation/widgets/website_sheet.dart';
import 'package:detoxo/features/protected_apps/protected_apps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

/// Spoken weekday names for the day chips, whose visible labels are the
/// three-letter abbreviations `RuleSummary.dayLabel` renders.
const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// The catalog's distracting categories — what the one-tap quick-pick toggles.
/// The catalog owns the set: `LockScope.distracting` widens to the same one.
final List<String> _distracting = Catalog.bundled.categoriesWithBehavior(AppBehavior.distracting);

/// Create / edit one rule. Draft state lives here until Save; the app-wide
/// [RulesCubit] persists and pushes.
class RuleEditorScreen extends StatefulWidget {
  const RuleEditorScreen({required this.args, super.key});

  final RuleEditorArgs args;

  /// One outline glyph per catalog category, so the rail can be scanned
  /// rather than read. Keyed by seed id; `test/rule_editor_test.dart` pins
  /// that every seed category has one, so a new category cannot ship bare.
  @visibleForTesting
  static const Map<String, IconData> categoryIcons = {
    'short_form_video': Icons.movie_filter_outlined,
    'social': Icons.people_outline,
    'video_streaming': Icons.live_tv_outlined,
    'games': Icons.sports_esports_outlined,
    'news': Icons.newspaper_outlined,
    'messaging': Icons.chat_bubble_outline,
    'browsers': Icons.language,
    'tools': Icons.handyman_outlined,
    'productivity': Icons.work_outline,
    'education': Icons.school_outlined,
  };

  /// The quick-pick's rule, pure so it can be pinned: when every id in [all]
  /// is already in [current], tapping clears them; otherwise it adds the
  /// missing ones and touches nothing else.
  @visibleForTesting
  static List<String> toggleAll(List<String> current, List<String> all) {
    if (all.every(current.contains)) {
      return [
        for (final id in current)
          if (!all.contains(id)) id,
      ];
    }
    return [
      ...current,
      for (final id in all)
        if (!current.contains(id)) id,
    ];
  }

  @override
  State<RuleEditorScreen> createState() => _RuleEditorScreenState();
}

class _RuleEditorScreenState extends State<RuleEditorScreen> {
  late final TextEditingController _name;
  late final RuleKind _kind;
  late Set<int> _days;
  late int _startMin;
  late int _endMin;
  late int _minutes;
  late int _opens;
  late List<String> _apps;
  late List<String> _websites;
  late List<String> _platforms;
  late List<String> _categories;
  late bool _strict;

  /// M8. Set once, at creation — an existing locked rule can never be
  /// unlocked here, and `LockGuard` refuses it in the domain layer too.
  late bool _locked;
  late LockScope _lockScope;

  /// Labels for the selected apps' chips, from the process-wide installed-apps
  /// cache; a package the scan does not know falls back to its id.
  Map<String, String> _appLabels = const {};
  bool _saving = false;

  Rule? get _existing => widget.args.rule;

  /// "Edit" means the rule is STORED, not merely passed in: a preset stamp and
  /// the Activity row's "Limit this app" both arrive as a fresh, unsaved Rule
  /// and must read as new — "Save rule", "created", and no Delete button that
  /// would remove nothing and quietly discard the draft.
  late final bool _isEdit;

  @override
  void initState() {
    super.initState();
    final r = _existing;
    _isEdit = r != null && context.read<RulesCubit>().state.rules.any((x) => x.id == r.id);
    _kind = r?.kind ?? widget.args.kind;
    _name = TextEditingController(text: r?.name ?? '');
    final s = r?.schedule;
    _days = {...(s?.days ?? RuleSchedule.weekdays)};
    _startMin = s?.startMin ?? 9 * 60;
    _endMin = s?.endMin ?? 17 * 60;
    _minutes = r == null || r.thresholdMs == 0 ? 30 : r.thresholdMs ~/ 60000;
    _opens = r == null || r.maxOpens == 0 ? 5 : r.maxOpens;
    _apps = [...(r?.selection.apps ?? const [])];
    _websites = [...(r?.selection.websites ?? const [])];
    _platforms = [...(r?.selection.platforms ?? const [])];
    _categories = [...(r?.selection.categories ?? const [])];
    _strict = r?.strict ?? false;
    _locked = r?.locked ?? false;
    _lockScope = r?.lockScope ?? LockScope.selection;
    sl<EngineRepository>().installedApps().then((apps) {
      if (!mounted || apps == null) return;
      setState(() {
        _appLabels = {for (final a in apps) a.packageName: a.appName};
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _defaultName => switch (_kind) {
    RuleKind.schedule => 'Schedule',
    RuleKind.timeLimit => 'Time limit',
    RuleKind.openLimit => 'Open limit',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassScaffold(
      appBar: GlassAppBar(title: Text(_isEdit ? 'Edit rule' : 'New ${_kind.label.toLowerCase()}')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          TextField(
            controller: _name,
            // Bounded like every other input here: the name is persisted and
            // rendered in a list row and on the dashboard card.
            maxLength: 40,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: _defaultName,
              prefixIcon: Icon(ruleKindIcon(_kind)),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          switch (_kind) {
            RuleKind.schedule => _scheduleSection(text),
            RuleKind.timeLimit => _budgetSection(
              text,
              headline: '$_minutes minutes a day',
              hint: 'Once the budget is spent, the apps block until midnight.',
              slider: AdaptiveSlider(
                value: _minutes.toDouble(),
                min: 5,
                max: 240,
                divisions: 47,
                semanticFormatter: (v) => '${v.round()} minutes',
                onChanged: (v) => setState(() => _minutes = v.round()),
              ),
            ),
            RuleKind.openLimit => _budgetSection(
              text,
              headline: '${RuleSummary.count(_opens, 'open', 'opens')} a day',
              hint: 'After that many launches, the apps block until midnight.',
              slider: AdaptiveSlider(
                value: _opens.toDouble(),
                min: 1,
                max: 20,
                divisions: 19,
                semanticFormatter: (v) => '${v.round()} opens',
                onChanged: (v) => setState(() => _opens = v.round()),
              ),
            ),
          },
          const SizedBox(height: AppSpacing.md),
          // Concrete targets first (the apps, feeds and sites the user has in
          // mind), categories below them; Commitment comes after both, so the
          // rule says what it covers before it is asked how hard to hold.
          const SectionHeader('Block'),
          GlassListTile(
            leading: const Icon(Icons.apps),
            title: 'Apps',
            subtitle: _apps.isEmpty ? 'None selected' : _count(_apps.length, 'app'),
            trailing: const Icon(Icons.add_circle_outline),
            onTap: _pickApps,
          ),
          if (_apps.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            _removableChips(
              _apps,
              (pkg) => _appLabels[pkg] ?? pkg,
              (pkg) => setState(() => _apps.remove(pkg)),
            ),
          ],
          if (_kind == RuleKind.schedule) ...[
            const SizedBox(height: AppSpacing.xs),
            GlassListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: 'Reel feeds',
              subtitle: _platforms.isEmpty ? 'None selected' : _count(_platforms.length, 'feed'),
              trailing: const Icon(Icons.add_circle_outline),
              onTap: _pickPlatforms,
            ),
            const SizedBox(height: AppSpacing.xs),
            GlassListTile(
              leading: const Icon(Icons.public),
              title: 'Websites',
              subtitle: _websites.isEmpty ? 'None selected' : _count(_websites.length, 'site'),
              trailing: const Icon(Icons.add_circle_outline),
              onTap: _pickWebsites,
            ),
            if (_websites.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              _removableChips(_websites, (h) => h, (h) => setState(() => _websites.remove(h))),
            ],
          ] else
            const InlineHint(
              icon: Icons.info_outline,
              text:
                  'Limits count app time from Android usage access, so they '
                  'apply to apps and categories.',
            ),
          const SizedBox(height: AppSpacing.md),
          // A heading, like every other group label on this screen, so
          // heading navigation lands on it and the quick-pick has context.
          Semantics(header: true, child: Text('Categories', style: text.labelLarge)),
          const SizedBox(height: AppSpacing.xs),
          // Seed order is behaviour order (distracting first), so the top row
          // is the usual suspects and the quick-pick that opens it covers them.
          ChipRail(
            leading: AppChip(
              label: 'All distracting',
              // The lock section's "every distracting app" is a different set
              // (packages, re-resolved at push); name the noun this one toggles.
              semanticLabel: 'All distracting categories',
              icon: Icons.bolt_outlined,
              selected: _distracting.every(_categories.contains),
              onSelected: () => setState(
                () => _categories = RuleEditorScreen.toggleAll(_categories, _distracting),
              ),
            ),
            chips: [
              for (final c in AppCategorySeed.categories)
                AppChip(
                  label: c.displayName,
                  icon: RuleEditorScreen.categoryIcons[c.id],
                  selected: _categories.contains(c.id),
                  onSelected: () => setState(() {
                    _categories.contains(c.id) ? _categories.remove(c.id) : _categories.add(c.id);
                  }),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const SectionHeader('Commitment'),
          // A locked rule is committed: strict is implied and no longer the
          // user's to change, so the toggle goes away rather than sitting
          // there greyed out.
          if (!_locked)
            AppToggleTile(
              leading: const Icon(Icons.lock_outline),
              title: 'Strict',
              subtitle: "A Pause won't lift this rule",
              value: _strict,
              onChanged: (v) => setState(() => _strict = v),
            ),
          SizedBox(height: AppSpacing.xs),
          if (_strict && !_locked) ...[
            const SizedBox(height: AppSpacing.xs),
            const InlineHint(
              icon: Icons.info_outline,
              text:
                  'Strict rules keep blocking apps, reel feeds and websites '
                  'even while Detoxo is paused. Turn this on for the rules you '
                  'set because you know future-you will want to skip them.',
            ),
          ],
          ..._lockSection(context),
          const SizedBox(height: AppSpacing.xl),
          PrimaryButton(
            label: _isEdit ? 'Save changes' : 'Save rule',
            expand: true,
            onPressed: _saving ? null : _save,
          ),
          // A locked rule shows NO delete button — absent, not greyed, the
          // same rule the list applies to its toggle. `LockGuard` refuses it in
          // the domain either way; this stops the user learning that the hard
          // way. Gated on the STORED lock, so ticking "Lock this rule" in the
          // draft does not make the button vanish before it is saved.
          if (_isEdit && !(_existing?.locked ?? false)) ...[
            const SizedBox(height: AppSpacing.sm),
            GhostButton(label: 'Delete rule', onPressed: _delete),
          ],
        ],
      ),
    );
  }

  Widget _scheduleSection(TextTheme text) {
    final overnight = _endMin < _startMin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('When'),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xxs,
          children: [
            for (var d = 1; d <= 7; d++)
              AppChip(
                label: RuleSummary.dayLabel(d),
                // Full weekday for screen readers: "Mon" is a glyph, not a word.
                semanticLabel: _weekdayNames[d - 1],
                selected: _days.contains(d),
                onSelected: () => setState(() {
                  _days.contains(d) ? _days.remove(d) : _days.add(d);
                }),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: GlassListTile(
                title: 'Starts',
                subtitle: localTimeFormat(context)(_startMin),
                trailing: const Icon(Icons.schedule),
                onTap: () => _pickTime(start: true),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: GlassListTile(
                title: 'Ends',
                subtitle: localTimeFormat(context)(_endMin),
                trailing: const Icon(Icons.schedule),
                onTap: () => _pickTime(start: false),
              ),
            ),
          ],
        ),
        if (_startMin == _endMin)
          const InlineHint(
            icon: Icons.error_outline,
            text: 'Start and end cannot be the same time.',
          )
        else if (overnight)
          const InlineHint(
            icon: Icons.nightlight_round,
            text: 'Ends the next morning — the whole night counts as the start day.',
          ),
      ],
    );
  }

  Widget _budgetSection(
    TextTheme text, {
    required String headline,
    required String hint,
    required Widget slider,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionHeader('Daily budget'),
      Text(headline, style: text.headlineSmall),
      slider,
      InlineHint(icon: Icons.info_outline, text: hint),
    ],
  );

  Widget _removableChips(
    List<String> items,
    String Function(String) label,
    void Function(String) onRemove,
  ) => Wrap(
    spacing: AppSpacing.xs,
    runSpacing: AppSpacing.xs,
    children: [
      for (final item in items)
        AppChip(
          label: label(item),
          // The chip LOOKS selected but activating it deletes the target —
          // "Instagram, selected" would be a trap for a screen reader user.
          semanticLabel: 'Remove ${label(item)}',
          selected: true,
          icon: Icons.close,
          onSelected: () => onRemove(item),
        ),
    ],
  );

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _startMin : _endMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: start ? 'Blocking starts' : 'Blocking ends',
    );
    if (picked == null || !mounted) return;
    setState(() {
      final m = picked.hour * 60 + picked.minute;
      if (start) {
        _startMin = m;
      } else {
        _endMin = m;
      }
    });
  }

  Future<void> _pickApps() async {
    // Protected apps cannot be targeted (one role per app; protection wins
    // natively anyway) — the picker says so instead of failing silently.
    final protected = await sl<ProtectedAppsRepository>().load();
    if (!mounted) return;
    final picked = await showAppPickerSheet(
      context,
      title: 'Choose apps',
      confirmLabel: 'Add',
      loadApps: sl<EngineRepository>().installedApps,
      refreshApps: () => sl<EngineRepository>().installedApps(refresh: true),
      unavailable: {
        for (final p in _apps) p: 'Added',
        for (final a in ProtectedAppCatalog.apps) a.packageName: 'Auto-protected',
        for (final a in protected) a.packageName: 'Protected',
      },
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      for (final app in picked) {
        if (!_apps.contains(app.packageName)) _apps.add(app.packageName);
        _appLabels = {..._appLabels, app.packageName: app.appName};
      }
    });
  }

  Future<void> _pickPlatforms() async {
    final engine = sl<EngineRepository>();
    final targets = await sl<ConfigRepository>().loadBlockTargets(
      installedPackages: await engine.installedPackages(),
    );
    if (!mounted) return;
    final options = [
      for (final t in targets)
        if (!t.isBrowser && (t.isInstalled || _platforms.contains(t.platformId)))
          (id: t.platformId, label: t.displayName),
    ];
    final picked = await ReelFeedSheet.show(
      context,
      title: 'Reel feeds',
      options: options,
      selected: _platforms.toSet(),
    );
    if (picked == null || !mounted) return;
    setState(() => _platforms = options.map((o) => o.id).where(picked.contains).toList());
  }

  Future<void> _pickWebsites() async {
    final picked = await WebsiteSheet.show(context, initial: _websites);
    if (picked == null || !mounted) return;
    setState(() => _websites = picked);
  }

  /// M8's "Lock this rule" — the strongest commitment the app offers, and the
  /// only one that cannot be undone from inside it.
  ///
  /// Three states, deliberately different shapes:
  /// * **Not yet locked** — a toggle plus a blunt confirmation. Locking is a
  ///   one-way door, so it asks once, in plain words.
  /// * **Locked in the DRAFT but not saved** — the toggle stays, and stays
  ///   undoable. Nothing is committed until Save, and dropping the toggle here
  ///   made a mis-tap escapable only by leaving the editor and losing every
  ///   other pending edit — punishing the user for a decision the app had not
  ///   yet acted on.
  /// * **Already locked in the STORED rule** — no toggle at all (an off switch
  ///   that refuses is an invitation to keep tapping), a standing notice, and
  ///   the honest way out: spend one override.
  List<Widget> _lockSection(BuildContext context) {
    final committed = _existing?.locked ?? false;
    if (!_locked) {
      return [
        AppToggleTile(
          leading: const Icon(Icons.lock),
          title: 'Lock this rule',
          subtitle: 'No off switch. Lifting it costs an override.',
          value: false,
          onChanged: (v) async {
            if (!v) return;
            final ok = await AppDialog.confirm(
              context: context,
              title: 'Lock this rule?',
              message:
                  'A locked rule has no off switch and cannot be deleted — not '
                  'now, and not later. You can lift it for up to an hour with '
                  'an override, twice a week.\n\nThe only way to remove it is '
                  'Settings → Reset app data.',
              confirmLabel: 'Lock it',
              destructive: true,
            );
            if (ok && mounted) setState(() => _locked = true);
          },
        ),
      ];
    }
    return [
      if (!committed) ...[
        AppToggleTile(
          leading: const Icon(Icons.lock),
          title: 'Lock this rule',
          subtitle: 'Takes effect when you save.',
          value: true,
          onChanged: (v) {
            if (!v) setState(() => _locked = false);
          },
        ),
      ],
      const SizedBox(height: AppSpacing.xs),
      InlineHint(
        icon: Icons.lock,
        text: committed
            ? 'This rule is locked. It has no off switch, it cannot be '
                  'deleted, and a Pause does not lift it. You can widen it, '
                  'but not narrow it. To get in anyway, spend an override.'
            : 'Saving locks this rule. After that it has no off switch, it '
                  'cannot be deleted, and a Pause does not lift it — the only '
                  'way in is an override.',
      ),
      // Schedules only: `resolveSnapshot` never widens a limit (its budget
      // would widen with it), so offering the one-way toggle there committed
      // the user to a setting that did nothing.
      if (_kind == RuleKind.schedule) ...[
        const SizedBox(height: AppSpacing.xs),
        AppToggleTile(
          leading: const Icon(Icons.auto_awesome_motion),
          title: 'Cover every distracting app',
          subtitle: 'Keeps holding as new ones are installed',
          value: _lockScope == LockScope.distracting,
          // Widening only: a lock that covers less than it did is a lock being
          // picked apart, and `LockGuard` refuses that anyway.
          onChanged: _lockScope == LockScope.distracting
              ? null
              : (v) => setState(() => _lockScope = v ? LockScope.distracting : _lockScope),
        ),
      ],
      // The STORED rule, not the draft: ticking "Lock this rule" and then
      // spending an override before saving would burn quota on a rule that is
      // not locked — and `resolveSnapshot` would have nothing to lift.
      if (_existing?.locked ?? false) ...[
        const SizedBox(height: AppSpacing.sm),
        OverrideTile(rule: _existing!),
      ],
    ];
  }

  Future<void> _save() async {
    final schedule = _kind == RuleKind.schedule
        ? RuleSchedule(days: _days, startMin: _startMin, endMin: _endMin)
        : null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rule = Rule(
      id: _existing?.id ?? const Uuid().v4(),
      name: _name.text.trim().isEmpty ? _defaultName : _name.text.trim(),
      kind: _kind,
      createdAtMs: _existing?.createdAtMs ?? now,
      enabled: _existing?.enabled ?? true,
      selection: RuleSelection(
        mode: _existing?.selection.mode ?? SelectionMode.block,
        apps: _apps,
        categories: _categories,
        websites: _kind == RuleKind.schedule ? _websites : const [],
        // Platforms survive a TIME limit now that `_limitEntry` meters reel
        // time for one: blanking them here re-saved onboarding's starter rule
        // as a rule with no targets at all, so renaming it quietly killed it.
        // An open limit still counts launches per package, which a feed has
        // none of, so it keeps dropping them.
        platforms: _kind == RuleKind.openLimit ? const [] : _platforms,
      ),
      schedule: schedule,
      thresholdMs: _kind == RuleKind.timeLimit ? _minutes * 60000 : 0,
      maxOpens: _kind == RuleKind.openLimit ? _opens : 0,
      strict: _strict,
      locked: _locked,
      lockScope: _lockScope,
    );
    // Same check the cubit re-runs before it persists — one helper, no copies.
    final error = rule.validate();
    if (error != null) {
      GlassToast.show(context, error, tone: AppTone.warning);
      return;
    }
    setState(() => _saving = true);
    final cubit = context.read<RulesCubit>();
    final ok = await cubit.save(rule);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      // Read, then clear: the list screen underneath leaves an error raised
      // from here alone, so it is this screen's to consume.
      final message = cubit.state.error ?? RulesCubit.saveFailed;
      cubit.clearError();
      GlassToast.show(context, message, tone: AppTone.warning);
      return;
    }
    GlassToast.show(context, _isEdit ? 'Rule saved.' : 'Rule created.', tone: AppTone.success);
    context.pop();
  }

  Future<void> _delete() async {
    final confirmed = await AppDialog.confirm(
      context: context,
      title: 'Delete this rule?',
      message: 'Its targets are unblocked right away.',
      confirmLabel: 'Delete',
      destructive: true,
      icon: Icons.delete_outline,
    );
    if (!confirmed || !mounted) return;
    final cubit = context.read<RulesCubit>();
    final ok = await cubit.remove(_existing!.id);
    if (!mounted) return;
    if (ok) {
      context.pop();
    } else {
      // Read the cubit's own message, like `_save` does: "this rule is locked"
      // and "your rules didn't load" are not the same problem, and neither is
      // "couldn't save — try again".
      final message = cubit.state.error ?? RulesCubit.saveFailed;
      cubit.clearError();
      GlassToast.show(context, message, tone: AppTone.warning);
    }
  }

  static String _count(int n, String noun) => '${RuleSummary.count(n, noun, '${noun}s')} selected';
}
