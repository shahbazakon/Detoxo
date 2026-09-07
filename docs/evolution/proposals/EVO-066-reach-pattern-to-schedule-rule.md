# EVO-066 — Turn the day's reach pattern into a standing schedule rule

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics/insights` (domain + presentation), reaching `lib/features/limits/rules` through the `limits` barrel
- Commit: 185c7f7 (working tree uncommitted — the 2026-09-07 restyle and the 2026-09-08 Tier-1 batch are not yet committed)
- Date: 2026-09-08
- Effort: M

## Why
The rollup keeps *how much* but never *when*. `DailyStats`
(`lib/features/analytics/insights/domain/entities/daily_stats.dart:70-77`) stores only
`pickupCount` / `firstPickupMs` / `lastPickupMs`, and the fold
(`lib/features/analytics/insights/domain/usecases/compute_daily_stats.dart:73-96`) already walks
every event for opens and pickups and throws each timestamp away:
```dart
  final opens = countOpens(kept);
  var totalOpens = 0;
  var distractionOpens = 0;
  opens.forEach((pkg, n) {
    totalOpens += n;
    if (catalog.behaviorForPackage(pkg) == AppBehavior.distracting) {
      distractionOpens += n;
    }
  });
```
Everything downstream of knowing the hour exists already: `RuleSchedule(days, startMin, endMin)`
(`lib/features/limits/rules/domain/entities/rule.dart:144-152`), `RuleEditorArgs(kind:, rule:)`
(`lib/features/limits/rules/domain/entities/rule_editor_args.dart:10-15`), and the prefilled-editor
precedent in `lib/features/analytics/presentation/widgets/app_limit_row.dart:66-81`. Doc 28 §3
records that a generic `foldSlices` was skipped because no consumer shipped — this is the consumer,
and it needs one 24-slot bucket in the walk that already runs, not the generic abstraction.

## Expected user impact
"You open Instagram most between 22:00 and midnight — 5 of the last 7 nights" with a **Set a
schedule** action that opens the rule editor prefilled with that app and that window. Saving it
means the feed is gated natively before the reach happens (EVO-029 reconciles limits at the
watchdog tick), whether or not Detoxo's UI is running. It is the only output on the Activity screen
that acts *before* the next scroll instead of after it — the report becomes a pre-emptive gate.

## Technical complexity
Dart only. The pure fold gains a 24-slot hourly histogram of distracting opens, filled in the single
existing walk over `kept`, and a "peak window" is derived only above a minimum sample (≥ 3 days with
data, never on a denied grant — the EVO-014 / EVO-035 honesty rule: no claim the data cannot carry).
One UI line plus the existing editor push. `queryUsageEvents` already takes an arbitrary window
(`lib/core/platform_channels/engine_channel.dart:213`, `CommandHandler.kt:324-341`). No new channel
method or payload key, no new permission, no new route, no new `StoreKey`. Strategy B (chosen)
persists nothing.

## Performance impact
One `queryUsageEvents` over the last 7 days, once per day key, memoised on the cubit; the native
handler sizes it in its own comment ("A day of events is a few hundred rows; a week a few
thousand", `CommandHandler.kt:340`), runs it on `ioExecutor` and posts the reply back — the same
shape as the query the screen already makes. The fold is O(n) with one int increment per event and
no per-row allocation. Nothing ticks, streams or touches the accessibility hot path (doc 28 §6's
"no ticker, no stream, no background job" rule holds).

## Business value
`docs/info_docs/01-product-overview.md` § "The problem": "Most 'screen-time' tools only tell you
about it the next morning, in a chart you close and forget." A schedule minted from the user's own
pattern is the one Activity output that survives closing the screen, and it extends § "App &
website blocking, and daily limits" from hand-authored rules to rules the app proposes from
evidence — a claim no generic wellbeing dashboard makes offline.

## Rejected alternative
Persist a 24-slot hourly histogram per day inside the existing `usage_daily` document and aggregate
the complete days. Rejected: it says nothing for weeks on a new install and only for days already
granted (`today()` returns `UsageDenied` before it ever persists), it widens the whole-document
rewrite whose ceiling doc 28 §4's `ponytail:` marker already names, and it needs a read path for 90
records written without the field. The chosen strategy can be upgraded to it later without touching
the UI.

## Rollback
Revert the Dart files. Nothing persisted; a rule the user saved from the suggestion is an ordinary
`Rule` and stays.

## Implementation Plan

### Current state
`compute_daily_stats.dart:24-40` — `computeDailyStats({usage, events, catalog, start, end,
protectedPackages, reelCount, complete, computedAtMs})`, pure, returns `DailyStats`.
`compute_daily_stats.dart:73-96` — the excerpt above; `kept` is the sorted, window-filtered event
list.
`lib/features/analytics/insights/domain/repositories/insights_repository.dart` — `today()`,
`cached(dayKey)`, `hasAccess()`.
`lib/features/analytics/insights/presentation/insights_cubit.dart:48-111` — `_compute()`; `state`
is `InsightsState(status, stats, yesterday, apps)`.
`lib/features/analytics/presentation/widgets/by_app_section.dart` — the By app panel; the
suggestion line goes under it (its own `SectionHeader`-less line, `AppSpacing.sm` below the panel).
`app_limit_row.dart:66-81`:
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

### Target state
- New pure use case `lib/features/analytics/insights/domain/usecases/peak_window.dart`:
  `PeakWindow? peakWindow(List<UsageEvent> events, {required Catalog catalog, required Set<String>
  protectedPackages, required DateTime now, int minDays = 3})` — buckets distracting
  `moveToForeground` opens (same `countOpens` run rule) by local hour per package over the events'
  day span, and returns the package + contiguous 2-hour window with the most opens, plus
  `daysHit` / `daysSampled`, or null when `daysSampled < minDays` or the best window has fewer than
  `minDays` hits. Protected packages never appear. Entity `PeakWindow(package, startHour, endHour,
  daysHit, daysSampled)` in `domain/entities/`.
- `InsightsRepository.peakWindow()` → one `queryUsageEvents(now - 7 days at local midnight, now)`
  through the usage layer; `UsageDenied` / `UsageUnavailable` → null. Memoised by day key on the
  repository (the `_memoDays` idiom) so a tab switch does not re-query.
- `InsightsState` gains `PeakWindow? peak`; `_compute()` resolves it after the labels emit (third
  emit, same "numbers first" reasoning as the labels).
- UI: `PeakWindowLine` under the By app panel — `"You open <label> most between 22:00 and 00:00 —
  5 of the last 7 days"` in `bodySmall` muted, with a `SecondaryButton('Set a schedule')` that
  pushes `Routes.ruleEditor` with `RuleEditorArgs(kind: RuleKind.schedule, rule: Rule(id: uuid,
  name: 'Evenings off <label>', kind: RuleKind.schedule, createdAtMs: now, schedule:
  RuleSchedule(days: {1..7}, startMin: startHour * 60, endMin: endHour * 60), selection:
  RuleSelection(apps: [package])))`. Hidden when `peak == null`. Never rendered on
  `InsightsStatus.denied` / `unavailable`.
- Copy: "Conscious" never appears here; no plan strings.

### Repo conventions to follow
- Pure logic as a top-level function in `domain/usecases/` with its own test
  (`test/insights_compute_test.dart` is the exemplar for `computeDailyStats`).
- The row's editor push (`app_limit_row.dart:66-81`) for the prefilled editor; `RuleKind.schedule`
  is the kind the editor already handles.
- Truthful empty states (EVO-014): no line without a sample.
- Buttons from `lib/core/design_system/components/buttons.dart`.

### Steps
1. `domain/entities/peak_window.dart` + `domain/usecases/peak_window.dart` with
   `test/peak_window_test.dart` (bucketing, the 2-hour window choice, `minDays`, protected packages
   excluded, denied → null).
2. `InsightsRepository.peakWindow()` + impl with the 7-day query and the day-key memo; a test in
   `test/insights_rollup_test.dart`.
3. `InsightsState.peak` + the third emit in `_compute()`; `test/insights_cubit_test.dart` case.
4. `presentation/widgets/peak_window_line.dart`; wire it under `ByAppSection` in
   `analytics_screen.dart`; `test/activity_screen_test.dart` — the line renders with a peak and
   tapping the button lands on the editor with a schedule rule for that package.
5. Docs: `docs/code_docs/28-insights.md` §3 (the fold), §5 (the new query), §6 (the line);
   `docs/code_docs/27-rules-engine.md` if the editor gains nothing (it should not);
   `info_docs/02` §15 (hand over — user-owned).

### Boundaries
Do not add a persisted field to `usage_daily`. Do not change `computeDailyStats`'s signature. Do
not auto-save a rule — the editor is where the user confirms (EVO-031). Do not touch native. If
`compute_daily_stats.dart:73-96` or `app_limit_row.dart:66-81` have drifted from the excerpts,
STOP and report.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: no persisted state · denied / unavailable grant renders nothing ·
      offline · no new manifest permission · the 7-day query's failure path lands in the
      existing `on Object` catch and Crashlytics
- [ ] Native untouched; manual check: the line on a device with ≥ 3 days of usage, and the
      saved schedule blocking at the window start with the app in the background
- [ ] `/docs-sync` run; mapped docs updated
