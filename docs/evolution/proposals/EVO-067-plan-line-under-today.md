# EVO-067 — Say which plan produced these numbers, and offer the stricter gate from Activity

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics` (presentation), reading and writing `SettingsCubit` through the `blocking` barrel
- Commit: 185c7f7 (working tree uncommitted — the 2026-09-07 restyle and the 2026-09-08 Tier-1 batch are not yet committed)
- Date: 2026-09-08
- Effort: S

## Why
`lib/features/analytics/presentation/widgets/today_overview.dart:23-34` puts "Reels seen 61"
beside "Blocked today 3" with no statement of which gate was live:
```dart
    final (reels, reelsTotal) = context.select(
      (ContentCounterCubit c) => (c.state.today, c.state.total),
    );
    final (blocks, blocksTotal, blocksYesterday) = context.select(
      (ServiceCubit c) =>
          (c.state.blocksToday, c.state.blocksTotal, c.state.blocksYesterday),
    );
```
`analytics_screen.dart:1-12` imports `blocking` only for `ServiceCubit` and the counter — the
screen has no read of `AppSettings.activePlan` / `masterEnabled` / `pauseSession` / `reelAllowance`
(`lib/features/blocking/shared/domain/entities/app_settings.dart:19-26`) and no way to change them,
while `SettingsCubit` is app-wide (`main.dart:94`) with `setPlan`
(`lib/features/blocking/shared/presentation/settings_cubit.dart:79`) and the plan's UI label is
already centralised (`lib/features/blocking/shared/domain/entities/enums.dart:27-33`,
`planLabel(plan, allowance:)` — `BlockingPlan.curious => 'Conscious'`). The plan is the product's
main lever, and the evidence for changing it lands here with the lever a tab away.

## Expected user impact
A single line under the Today panel states the gate the numbers were produced under — "Conscious ·
61 seen, 3 blocked", "Paused until 21:40 · counting only", "Blocking off · counting only", "One
Reel · 61 seen, 3 blocked" — and, when a stricter gate exists (Conscious → Block All), offers it in
one tap. The user who just read 61 reels acts on the plan in the moment of recognition instead of
losing the impulse on the way to the Dashboard, and the numbers stop being quotable out of
context — the confident-lie class EVO-014 removed from screen time and EVO-063 removes from the
Blocks segment.

## Technical complexity
Dart only. One `context.select` on `SettingsCubit` through the blocking barrel
(`blocking.dart:33`, the first settings read in analytics — legal via the barrel) plus one
`setPlan(BlockingPlan.blockAll)` call. The truth rule is the hard part, not the widget:
`activePlan` alone is not the live state — a running pause is tracked in `pauseSession`
(`PauseSession(startedAt, pauseDuration, …)`, `lib/features/blocking/plans/domain/entities/sessions.dart:6-27`),
a legacy persisted `paused` collapses to Block All (`app_settings.dart:41-55`), `masterEnabled`
switches everything off, and One Reel / Unblock ride `reelAllowance` — so the line is derived by
one pure function with a test rather than printed from the enum. The wire token never renders:
labels come from `planLabel` only. Must not collide with approved EVO-062, which gives the *tiles*
a tap — this is a panel footer row, not a tile action. No new channel key, `StoreKey`, route or
barrel export.

## Performance impact
One subscription to a cubit that is already constructed and streamed app-wide, selected down to a
small record so it rebuilds one `Row` and not the four `StatCard` tweens (the `context.select`
discipline `today_overview.dart:30-34` documents). Plan changes are user-initiated and rare, so the
rebuild rate is effectively zero; `setPlan` reuses the existing commit + single native settings
push, adding no channel round trip and no work on the engine's per-event path.

## Business value
`docs/info_docs/01-product-overview.md` § "Blocking plans — pick your style" is the differentiator
the store listing leads with ("Choose how you want to change"), and § "Why Detoxo is different"
contrasts Detoxo against "one blunt app timer". A plan the user cannot re-evaluate against their own
numbers is a menu, not a system; putting the gate one tap from the evidence is what makes the plan
ladder (Block All / Conscious / One Reel / Unblock / Pause) a loop rather than a setup choice.

## Rejected alternative
A plan line whose action navigates to the Dashboard's `ModeSelector` so the full picker is reused.
Rejected: `ModeSelector` lives at `lib/features/dashboard/presentation/widgets/mode_selector.dart`
and dashboard has no barrel, so importing it would add the first new entry to
`tool/boundaries_baseline.txt` since it was cleared (a finding in itself), and there is no route to
a HomeShell tab, so from the pushed drawer route the navigation is undefined. One existing cubit
call, no new export, and one step offered rather than a picker re-implemented.

## Rollback
Revert the Dart files. A plan the user switched to through the line is an ordinary settings write
and stays.

## Implementation Plan

### Current state
`today_overview.dart:23-34` — the excerpt above; the panel is
`GlassCard(padding: xxs, child: Column([StatCardPair(...), if (stats != null) ...[Divider, StatCardPair(...)]]))`
(`:40-118`).
`app_settings.dart:19-26`:
```dart
    this.activePlan = BlockingPlan.blockAll,
    this.defaultBlockMode = BlockingMode.pressBack,
    this.enabledPlatformIds = const {},
    this.vibrationEnabled = true,
    this.masterEnabled = true,
    this.pauseSession,
    this.baseMode = BlockingPlan.blockAll,
    this.reelAllowance = 1,
```
`settings_cubit.dart:76-83`:
```dart
  /// Switch the active plan. Clears any live pause (the user is choosing a fresh
  /// plan). Choosing a base mode (Block All / Conscious) also records it as the
  /// sticky `baseMode` that override modes revert to.
  Future<void> setPlan(BlockingPlan plan) {
```
`enums.dart:27-33` — `planLabel`.
`sessions.dart:6-27` — `PauseSession(startedAt, pauseDuration, cooldownDuration, planToResume, allowInCooldown)`.

### Target state
- `TodayOverview` gains `@visibleForTesting static ({String text, bool offerBlockAll}) planLine(
  AppSettings s, {required int seen, required int blocked, required DateTime now})`:
  - `!s.masterEnabled` → `('Blocking off · counting only', false)`.
  - `s.pauseSession != null` and `now` is before `startedAt + pauseDuration` →
    `('Paused until HH:MM · counting only', false)` (24-hour clock, local; the app's one clock
    form — grep `HH:MM` copy in `lib/features/limits/rules/presentation/` for the formatter to reuse).
  - otherwise `('${planLabel(s.activePlan, allowance: s.reelAllowance)} · $seen seen, $blocked
    blocked', s.activePlan == BlockingPlan.curious)`.
- Rendered as the panel's last row after a hairline (the same `Divider` idiom as the tile rows):
  `Padding(sm)` → `Row([Expanded(Text(text, bodySmall, onGlassMuted)), if (offerBlockAll)
  SecondaryButton('Block All')])`. The button calls
  `context.read<SettingsCubit>().setPlan(BlockingPlan.blockAll)`; no dialog, no snackbar — the
  line re-renders "Block All · …" on the cubit's emit, which is the confirmation.
- Read: `context.select((SettingsCubit c) => (c.state.activePlan, c.state.masterEnabled,
  c.state.pauseSession, c.state.reelAllowance))`.
- Spoken: the row is one `Semantics(label: text)` with the button a separate labelled control.

### Repo conventions to follow
- Pure logic as a `@visibleForTesting static` on the widget (`ByAppSection.rowsFor` /
  `emptyCopy`, `by_app_section.dart:55-130`), tested in a `_test.dart` beside `by_app_rows_test`.
- `planLabel` for every plan string; never the enum name.
- `SecondaryButton` from `lib/core/design_system/components/buttons.dart`.
- The hairline + `Padding(sm)` inset of the tile rows (`today_overview.dart:77-84`).

### Steps
1. `today_overview.dart`: `planLine` static + a test file `test/plan_line_test.dart` (the four
   states, the Conscious-only offer, "Unblock" at `reelAllowance > 1`).
2. `today_overview.dart`: the select, the footer row, the button; `test/activity_screen_test.dart`
   adds a `SettingsCubit` provider (mocktail, the `test/resume_sync_test.dart` idiom) — the line
   renders, and tapping **Block All** calls `setPlan(BlockingPlan.blockAll)`.
3. Docs: `docs/code_docs/28-insights.md` §6 (the Today panel paragraph); `docs/code_docs/12-…md`
   §1; `docs/code_docs/03-detection-engine.md` / plans doc only if wording there names where the
   plan can be changed; `info_docs/02` §15 (hand over — user-owned).

### Boundaries
Do not offer any plan other than Block All (the one strictly stricter gate). Do not clear a pause
from this line. Do not import anything from `lib/features/dashboard/`. Do not make the tiles
tappable (EVO-062 owns that). If `today_overview.dart:23-34`, `app_settings.dart:19-26` or
`settings_cubit.dart:79` have drifted from the excerpts, STOP and report.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: the write goes through the existing settings commit + native push
      (survives process death and reboot via `ConfigStore`) · master-off and paused states are
      stated, not actioned · offline · no new manifest permission · no new failure paths
- [ ] Native untouched; manual check: on Conscious, tap **Block All** from Activity and confirm
      the next reel is blocked; start a pause on the Dashboard and confirm the line reads
      "Paused until …" with no button
- [ ] `/docs-sync` run; mapped docs updated
