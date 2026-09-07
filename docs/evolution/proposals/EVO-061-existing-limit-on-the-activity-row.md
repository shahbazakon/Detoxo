# EVO-061 — Show and edit an app's existing limit from its Activity row

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics` (presentation) + `lib/features/limits/rules` (read-only, via the barrel)
- Commit: 185c7f7 (working tree uncommitted — the Activity restructure and its Tier-1 batch of 2026-09-07 are not yet committed)
- Date: 2026-09-07
- Effort: S

## Why
`lib/features/analytics/presentation/widgets/app_limit_row.dart:55-71` always mints a new
`Rule` with a fresh `Uuid().v4()` and pushes the editor pre-filled for a *new* daily limit.
Nothing consults `RulesCubit.state.rules`, so an app that already has a time-limit rule gets a
second one on every tap — the "duplicate limit" item reported and left open in the 2026-09-06
batch (`docs/evolution/BACKLOG.md`, "Reported, not fixed"). The row also cannot tell the user a
limit already exists, so "1h 10m · Instagram" reads the same whether the app is capped at 30 m or
uncapped.

## Expected user impact
A By app row for an app with a time-limit rule shows the limit ("2h limit") and tapping it opens
*that* rule for editing; a row without one keeps today's behaviour (a pre-filled new rule). No
duplicates, and the number and the cap sit on one line — the moment of noticing is the moment of
acting (EVO-033's rule), now for the second and every later time as well as the first. This
strengthens the intervention loop directly: daily limits are how the "steps in while you're
scrolling" promise (`docs/info_docs/01-product-overview.md`, "Why Detoxo is different") reaches
whole apps.

## Technical complexity
Dart only. `RulesCubit` is provided app-wide (`lib/main.dart:151`) and exported from
`lib/features/limits/limits.dart:24`, so the analytics feature reads it through the barrel — no
boundary change. No channel keys, no storage keys, no manifest change.

## Performance impact
None on the hot path. One linear scan of `state.rules` (≤ 50 rules) per By app build, done in
`ByAppSection` once and passed down, not per row. `context.select` on the rules list keeps the
card from rebuilding on unrelated rules-state churn.

## Business value
Retention and the store-listing story both rest on "set daily limits" being a one-tap outcome of
seeing a number (`docs/info_docs/01-product-overview.md`, "App & website blocking, and daily
limits"). A duplicate rule is the opposite: it confuses the Rules screen and the native snapshot.

## Rejected alternative
Dedupe on save inside `RulesCubit.add` (refuse a second time-limit rule for the same single app).
It fixes the duplicate but not the blindness — the row would still not show the cap — and it
turns a UI mistake into a silent save refusal the user has to interpret. Lost on user impact.

## Rollback
Revert the two Dart files. No stored data changes; rules created before the change are untouched.

## Implementation Plan

### Current state
`lib/features/analytics/presentation/widgets/app_limit_row.dart:55-71`:
```dart
  Future<void> _limitThisApp(BuildContext context) {
    return context.push(
      Routes.ruleEditor,
      extra: RuleEditorArgs(
        kind: RuleKind.timeLimit,
        rule: Rule(
          id: const Uuid().v4(),
          name: 'Limit $_label',
          kind: RuleKind.timeLimit,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          // thresholdMs stays at its 0 default on purpose: the editor makes
          // the user choose a budget rather than accepting one Detoxo invented.
          selection: RuleSelection(apps: [package]),
        ),
      ),
    );
  }
```
`lib/features/analytics/presentation/widgets/by_app_section.dart:188-200` builds each
`AppLimitRow(key:, package:, installed:, name:, iconUrl:, trailing:, spokenTrailing:, fraction:)`.
`RulesState.rules` is `final List<Rule> rules;` (`lib/features/limits/rules/presentation/rules_cubit.dart:33`).
`Rule` carries `kind` (`RuleKind.timeLimit`), `selection.apps` (`List<String>`) and the
time-limit budget (`thresholdMs` — confirm the field name at `rule.dart:210-300` before editing).

### Target state
- `AppLimitRow` gains `final Rule? existing;`. When non-null: the trailing figure gets a muted
  second line `"${formatHm(Duration(milliseconds: existing.thresholdMs))} limit"` under the
  number (bodySmall, `context.glass.onGlassMuted`), the spoken label ends with
  `". Edit the 2h limit"` instead of `". Set a daily limit"`, and the tap pushes
  `RuleEditorArgs(kind: RuleKind.timeLimit, rule: existing)`.
- `ByAppSection` reads `final rules = context.select((RulesCubit c) => c.state.rules);` and
  passes `existing: ByAppSection.existingLimit(rules, package)`.
- New static `@visibleForTesting` `Rule? existingLimit(List<Rule> rules, String package)`:
  the first rule with `kind == RuleKind.timeLimit` whose `selection.apps` is exactly `[package]`
  (a limit shared across several apps is not "this app's limit" and must not be edited from one
  row). Null otherwise.

### Repo conventions to follow
- Pure logic as a static `@visibleForTesting` method: `ByAppSection.rowsFor`
  (`by_app_section.dart:54`) and `StreakCubit.advance`.
- Cross-feature read through the barrel only: `import 'package:detoxo/features/limits/limits.dart';`
  (already imported by `analytics_screen.dart`).
- Copy: "limit", never "cap" or "budget" in UI (matches the Rules screen).

### Steps
1. `app_limit_row.dart`: add `this.existing` to the constructor and field; branch `_limitThisApp`
   on `existing != null`; add the second trailing line and the spoken suffix.
2. `by_app_section.dart`: add `existingLimit`; select `rules`; pass `existing:` per row.
3. `test/by_app_rows_test.dart`: `existingLimit` returns the single-app time-limit rule, ignores a
   schedule rule and a two-app limit, and returns null when absent.
4. `test/activity_screen_test.dart`: provide a `RulesCubit` over a fake repository with one
   time-limit rule for `com.instagram.android`; assert the row reads "… limit" and its semantics
   label ends with "Edit the … limit"; tapping pushes the editor with that rule's id (assert via a
   `GoRouter` test observer or the pushed `extra`, the `web_block_screen_semantics_test` idiom).
5. Docs: `docs/code_docs/28-insights.md` (the EVO-033 paragraph), `docs/code_docs/12-…md` §1,
   `docs/info_docs/02-feature-walkthroughs.md` §15 (hand over, user-owned).

### Boundaries
Do not touch `RulesCubit`, the rule editor, `RuleRepository` or the native snapshot. Do not
dedupe on save. If `app_limit_row.dart:55-71` or `by_app_section.dart:188-200` no longer match the
excerpts above, STOP and report — do not improvise.

Drift note (2026-09-07): they have drifted — the Activity screen moved to `SectionHeader` + one
`GlassCard` panel per section, the row gained `vertical: AppSpacing.xs` (48 dp floor) and the rows
now sit inside a `GlassCard` (see `docs/evolution/BACKLOG.md`, "Activity screen: headed sections").
Re-read the target files and refresh the excerpts before executing; the row's data flow is unchanged.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: state survives process death + reboot (no new state) ·
      permission-revoked path handled (rules need none) · works offline · no new
      manifest permission · Crashlytics covers new failure paths (none new)
- [ ] Native untouched — no device sanity list
- [ ] `/docs-sync` run; mapped docs updated
