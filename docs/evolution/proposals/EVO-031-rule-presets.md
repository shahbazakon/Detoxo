# EVO-031 — One-tap rule presets

- Status: done (in the working tree; stamp the commit hash on commit)
- Tier: 2 (enhancement) — new user-facing capability
- Feature: `lib/features/limits/rules`
- Commit: 190042a
- Date: 2026-09-03
- Effort: S

## Why

The rules empty state asks for a blank-page decision:

`lib/features/limits/rules/presentation/rules_screen.dart`

```dart
                  title: 'No rules yet',
                  subtitle:
                      'Block apps on a schedule, or cap how long and how '
                      'often you use them each day.',
```

From there the user must pick a kind, name it, choose days, set two times, and pick
targets before anything is saved — six decisions before the first block exists. Everything
needed to skip that already ships: `RuleSchedule.weekdays`, `AppCategorySeed.categories`
and the catalog's category→package index (now O(1) after this run's LOW-cluster fix).

## Expected user impact

Three or four starter rules on the empty state and in the "New rule" sheet — "Work hours",
"Sleep", "Dinner", "Doomscroll hours" — each one tap to a **pre-filled editor** (not a
silent save), so the user reviews and adjusts before committing. Time from "I want this"
to "I have this" drops from six decisions to one plus a confirm.

Getting-started is currently three steps that end at the blocklist
(`docs/info_docs/01-product-overview.md`, §Getting started); rules are a fourth step
nobody is walked through. Presets are that walkthrough, in-place.

## Technical complexity

The smallest of the four. Pure Dart, no native, no wire, no storage change: a `const`
list of partially-built `Rule`s in the rules domain, rendered as chips or tiles, tapping
one pushes `Routes.ruleEditor` with a `RuleEditorArgs` whose `rule` is the preset with a
fresh `id` and `createdAtMs`. The editor already accepts exactly that shape.

The only real content decision is which categories each preset targets, and that comes
from the shipped seed rather than new data.

## Performance impact

None. A `const` list built at compile time, rendered on a screen that is not on the
detection path, feeding an editor route that already exists. No extra resolve, no extra
push — a preset only becomes a rule when the user saves it, through the same
`RulesCubit.save` as any other.

## Business value

Onboarding conversion, and the weakest of the four on differentiator grounds — this is
table stakes rather than a lead. It matters because an unused feature has no retention
value at all, and the current empty state is the kind that gets backed out of. It also
gives the store listing something concrete: the long description currently says only *"set
daily limits"* (§Long description), which presets turn into named, recognisable use cases.

## Rejected alternative

Ship presets as *templates the user cannot edit* — tap "Sleep" and it saves 22:00–07:00
across all categories immediately. Rejected: it hides what was created behind a name, and
the first thing a user does with "Sleep" is disagree with the hours. Pre-filling the
editor costs one extra tap and makes the preset a starting point instead of a black box.

## Rollback

Delete the const list and the two render sites. Rules created from a preset are ordinary
rules and are unaffected — there is no preset marker on the stored document, deliberately,
so nothing dangles.

## Implementation Plan

### Current state

`lib/features/limits/rules/presentation/rules_screen.dart` — the empty state offers one
generic CTA, and `_newRule` opens a kind picker:

```dart
    final kind = await GlassBottomSheet.show<RuleKind>(
      context: context,
      title: 'New rule',
```

`lib/features/limits/rules/presentation/rule_editor_screen.dart` already takes a fully
formed rule to edit:

```dart
class RuleEditorArgs {
  const RuleEditorArgs({required this.kind, this.rule});
```

### Target state

- New `lib/features/limits/rules/domain/entities/rule_preset.dart`:
  `class RulePreset { final String description; final Rule template; }` exposed as
  `RulePreset.all`, a `const` list. The template carries `id: ''` and `createdAtMs: 0`;
  `RulePreset.stamp(id:, createdAtMs:)` produces the savable rule (`Rule.copyWith`
  deliberately does not expose identity fields).
- Presets (targets by category id from `AppCategorySeed`):
  - **Work hours** — schedule, Mon–Fri 09:00–17:00, `short_form_video` + `social`
  - **Sleep** — schedule, every day 22:00–07:00 (overnight), `short_form_video` + `social` + `video_streaming`
  - **Dinner** — schedule, every day 19:00–20:00, `short_form_video`
  - **Doomscroll budget** — time limit, 30 min/day, `short_form_video`
- The empty state renders them as a `SectionHeader('Start from a preset')` plus
  `GlassListTile`s. **As shipped the "New rule" sheet was left alone**: the FAB is the
  blank-page entry point and the presets are the shortcut past it, so listing them in both
  places would have been the duplicate-CTA problem the audit flagged on this very screen.
- Tapping one pushes `Routes.ruleEditor` with
  `RuleEditorArgs(kind: p.template.kind, rule: p.stamp(id: const Uuid().v4(), createdAtMs: now))`.

### Repo conventions to follow

- Presets are domain data, exported through `lib/features/limits/limits.dart`.
- UI from `lib/core/design_system/components/` — `SectionHeader`, `GlassListTile`,
  `EmptyState` (all already used on this screen).
- Copy through `RuleSummary` where it describes a rule, so a preset's subtitle is
  generated by the same code that describes a saved one — no second copy of that string.
- Route args go through `state.extra` as `RuleEditorArgs`, the pattern already in
  `app_router.dart`.

### Steps

1. Add `rule_preset.dart` with the `const` list; export from the barrel.
2. `test/rules_engine_test.dart`: every preset's template passes `Rule.validate()` and
   resolves to at least one snapshot entry through `resolveSnapshot`. (This is the check
   that matters — a preset that cannot be saved is the only real failure mode.)
3. Render in the empty state.
4. Render in the "New rule" sheet above the kind rows.
5. Docs: `27-rules-engine.md`, `info_docs/02-feature-walkthroughs.md` §14.

### Boundaries

Do NOT save a preset without the editor — the user must confirm. Do NOT add a `preset` or
`source` field to the stored rule document. Do NOT add a dependency for icons; use the
`Icons.*` glyphs `ruleKindIcon` already returns. Keep the list to four; a preset gallery
is a different feature. If the code at the cited lines has drifted from the Commit stamp
above, STOP and report — do not improvise.

### Validation

- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (every preset validates and resolves)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS" intact in
      wire/code, "Conscious" in UI strings
- [ ] Production readiness: works offline; no new permission; a preset-created rule is
      indistinguishable from a hand-made one after save (survives process death + reboot
      by the same path)
- [ ] No native change → no device sanity list needed beyond opening the editor from each
      preset and saving one
- [ ] `/docs-sync` run; mapped docs updated
