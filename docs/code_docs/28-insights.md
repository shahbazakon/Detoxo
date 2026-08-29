# Insights — real screen time

Written from shipped source. The first Dart consumer of the usage signal layer
([26](26-catalog-and-usage-signal.md)): a pure daily fold, a 90-day rollup store, and a view inside
the existing Activity tab. Plan doc: [`plan_docs/05-M4-insights.md`](../plan_docs/05-M4-insights.md)
(shipped).

---

## 1. Why it exists

Before this, every time number in Detoxo was **inferred from gaps between accessibility events**.
`ContentCounter.onAppActivity` accrues foreground time only while events keep arriving within
`USAGE_ACTIVE_GAP_MS` (12 s), and says so itself at
[`engine/ContentCounter.kt`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt)
(§2.6 of [17](17-content-counter.md)):

> `ponytail: active-event heuristic — undercounts truly passive, event-quiet playback.`

That is precisely the behaviour the product exists to surface. `UsageStatsManager` has the correct
figure and M0.2 already built the pipe to it; this feature reads it. The reel counter is unchanged
and still owns the bubble, the widget and the daily-limit meter — insights sits **beside** it, not
over it.

## 2. Shape — `lib/features/analytics/insights/`

Lives inside the existing `analytics` feature (same concern: showing the user their own
behaviour) and is exported from `analytics.dart`. A second top-level feature would have needed a
second barrel and invited a boundary violation.

```
insights/
├── domain/entities/daily_stats.dart
├── domain/usecases/compute_daily_stats.dart      # PURE — zero platform imports
├── domain/repositories/insights_repository.dart
├── data/repositories/insights_repository_impl.dart
└── presentation/{insights_state.dart, insights_cubit.dart,
                  widgets/insights_view.dart}
```

## 3. `computeDailyStats` — the pure fold

`domain/usecases/compute_daily_stats.dart`. No platform imports, no clock, no I/O:

```dart
DailyStats computeDailyStats({
  required List<AppUsage> usage,      // from queryAppUsage
  required List<UsageEvent> events,   // from queryUsageEvents
  required Catalog catalog,
  required DateTime start,            // local midnight
  required DateTime end,              // next local midnight, or `now` for today
  Set<String> protectedPackages = const {},   // never reach topApps (EVO-032)
  int reelCount = 0, bool complete = false, int computedAtMs = 0,
})
```

Window is `[start, end)`. Native already windows the query; the fold filters and sorts again
anyway — one pass, and it is what makes the boundary behaviour a pinned test rather than a trust
assumption.

| Metric | Rule |
|---|---|
| `screenTimeMs` | Σ `foregroundMillis` (rows with `≤ 0` skipped, though native already drops them) |
| `distractionMs` | the same sum restricted to `catalog.behaviorForPackage(pkg) == distracting` |
| `distractionOpens` | Σ `countOpens(events)` over distracting packages |
| `contextSwitches` | `Σ countOpens(events).values − 1`, floored at 0 |
| `pickupCount` / `firstPickupMs` / `lastPickupMs` | the `screenInteractive` (type 18) events |
| `topApps` | usage sorted by `foregroundMillis` desc, `take(kTopAppsCap)` = 10, **minus every protected package** (EVO-032) |
| `reelCount` / `complete` | carried in, not derived |

Two details that are load-bearing:

- **Opens are transitions, not events.** `countOpens`
  ([`rule_calendar.dart`](../../lib/features/limits/rules/domain/usecases/rule_calendar.dart),
  exported from `limits.dart`) is reused rather than re-derived, so insights, the rules limiter and
  native `UsageQuery.countOpens` all mean the same thing by "an open". A raw event count would
  inflate every figure each time an app resumed its own next activity. The plan doc specified the
  raw count; this is a deliberate departure from it, for that reason.
- **`contextSwitches` is derived from the same walk.** `countOpens` counts every transition *into a
  different package*; the day's first foreground is a transition from nothing, so subtracting one
  is exactly the plan's `prevPkg != null` guard — with one list walk instead of two, and no second
  definition that can drift.

**Not implemented:** `unblockCount`. Its source is the `temporaryUnblocks` grant ledger, which
belongs to M2/M8 and does not exist yet; a field that is structurally always `0` would be a lie in
the store and in any later chart. Also not implemented: the plan's generic `foldSlices`, whose only
consumers would be M7 and a per-app timeline — neither shipped.

## 4. Storage — `StoreKeys.usageDaily` (`usage_daily`)

One JSON document in the `detoxo` Hive box, day-keyed, **90-day prune on write** — see
[09](09-persistence-data-model.md).

```jsonc
{ "days": { "02-09-2026": {
    "screenTimeMs": 11520000, "distractionMs": 6480000, "distractionOpens": 37,
    "pickupCount": 84, "firstPickupMs": …, "lastPickupMs": …,
    "contextSwitches": 142, "reelCount": 96,
    "topApps": [ { "package": "com.instagram.android", "ms": 4200000 } ],
    "computedAtMs": …, "complete": true
} } }
```

- **Day keys are `dd-MM-yyyy`, always via `daySignature`** — never the web blocker's
  `WebBlockStatsRepositoryImpl._todayKey` (`yyyy-MM-dd`), which remains the repo's one day-key
  format outlier and a separate cleanup.
- **`complete: false` while it is still today.** A partial day charted as a finished one makes
  every "today vs average" comparison read low until bedtime.
- **Pruning is chronological, not insertion-ordered** (`_sortableKey` maps `dd-MM-yyyy` →
  `yyyyMMdd`), so a backfilled record can never evict a newer one.
- A corrupt blob is logged and treated as absent — it must never take the screen down
  (the `WebBlockStatsRepositoryImpl` precedent).

`ponytail:` one JSON doc rewritten per recompute; fine at 90 days, not at 3 years. Upgrade path =
per-day keys or a real store.

## 5. `InsightsRepositoryImpl`

`InsightsRepositoryImpl(UsageRepository, ContentCounterRepository, ProtectedAppsRepository,
LocalStore, {clock, catalog})` — `clock` and `catalog` are injected so rollover and backfill are
testable without waiting for midnight. Registered in `injector.dart` beside `AnalyticsRepository`.

`today()`:

1. `todayInterval(now)` (reused from `limits.dart`) gives local midnight; the window is
   `[start, now)`. **At exactly midnight the window is empty**, so it answers a zero day without
   touching the channel — the same guard `rule_sync` uses. It still checks `hasAccess()` first:
   answering a confident `0 m` to someone who never granted Usage Access is the one thing this
   screen exists to prevent.
2. `queryAppUsage` + `queryUsageEvents`, then the pure fold with `Catalog.bundled` and the reel
   count from `ContentCounterRepository.current().today`. A counter failure costs the reel count
   (logged, degraded to 0), never the rest of the screen.
3. **Backfills yesterday** when that record is missing or incomplete, storing it `complete: true`.
   This is what the previous-day comparison reads, so the store is read as well as written.
   `ponytail:` one day, not seven — UsageStats retains ~7 days; deeper backfill lands with the
   history UI.
4. Persists both and prunes — **unless the write would replace a `complete: true` day with a
   partial one**, which is what a device clock moved backwards produces.

The document is decoded **once** per `today()` and threaded through the backfill and the write;
each `cached()` call re-parses all 90 days, and this method used to make four of them.

Grant handling is the whole reason the return type is `UsageQueryResult<DailyStats>`:

| Case | Answer |
|---|---|
| granted | `UsageGranted(stats)` |
| `UsageDenied` | `UsageDenied` — **never** a cached fallback and never an empty day. A stale figure presented as live is the same lie as `0 m`. |
| `UsageUnavailable` | today's cached record if one exists (the engine failed, but that number was real), otherwise `UsageUnavailable` |

`cached(dayKey)` is synchronous because `LocalStore.read` is.

Every recompute also reads `protectedPackagesFor(ProtectedAppsRepository.load())` and passes it
to the fold. A failed read degrades to the **bundled catalog** rather than to an empty set, so
the seeded banking / UPI / password-manager packages stay hidden either way.

## 6. Presentation

`InsightsCubit(InsightsRepository, EngineRepository, {clock})` over
`InsightsState { status, stats, yesterday, apps }` with
`enum InsightsStatus { loading, granted, denied, unavailable }`.

- `load()` / `refresh()` / `refreshIfStale()` — the last is a no-op unless the cached `dayKey` has
  gone stale, which is the resume path for a session held across midnight.
- An `_inFlight` guard stops a pull-to-refresh and a resume racing into two identical pairs of
  channel queries. Only the first read shows a spinner; a refresh keeps the numbers on screen.
- **`_compute` never throws.** Every failure path emits — a repository throw lands the user on
  the retryable "we couldn't read this" card rather than on a spinner that never resolves, which
  is what an uncaught throw produced.
- **Two emits on the granted path.** The numbers go out first; the installed-app labels follow
  once the native scan returns, with a second `isClosed` check before the second `emit`. Gating
  the first paint on an uncached label+icon scan withheld the whole screen for cosmetics, and
  the un-rechecked `await` threw `StateError` when the user left the tab mid-scan.
- The granted state is **built, not `copyWith`-ed**, so `yesterday` is set to exactly what
  `_completeYesterday()` returned. `copyWith`'s `?? this.yesterday` kept the previous day's
  record after a rollover and labelled it "yesterday".
- `yesterday` is populated **only when that day is `complete`** — comparing against a part-day
  would flatter today's figure.
- `apps` maps package → `InstalledApp` from `EngineRepository.installedApps()` (already
  process-cached) for labels and icons in the top-apps list. A failure costs the labels, not the
  numbers: rows fall back to the package name.

`InsightsView` is a `StatefulWidget` + `WidgetsBindingObserver` purely for that resume hook.
**No ticker, no stream, no background job, and it is not provided app-wide** — nothing is computed
at boot, and `AppResumeSync` is untouched.

What it draws, in order: a screen-time hero (`formatHm`, the distracting share as a shared
`ProgressBar`, and yesterday's finished total as a plain `"Yesterday: 4h"` reference); four
`StatCard`s (pickups, app switches, distracting opens, reels); the first/last-pickup row; the
top five apps as tappable bars; and a footnote stating the limits of the numbers.

**No percentage against yesterday** (EVO-035). Today is still running, so a percentage against
yesterday's *whole* day rendered "95% less than yesterday" every morning — true arithmetic, false
statement. `screenTimeDeltaPercent` now requires both days complete, so it is null on the live
screen and available to a future history view.

**Each top-app row opens a pre-filled daily-limit rule** (EVO-033) — `Routes.ruleEditor` with
`RuleEditorArgs(kind: timeLimit, ...)`, never a silent save. This is the one place the screen
stops being a report: seeing "1h 10m" against an app is the moment a limit gets set. It is why
`RuleEditorArgs` lives in `limits/rules/domain/` rather than `presentation/`.

The footnote is scoped to what Android actually produced: screen time, distraction time and the
app list are OS figures; reels seen is Detoxo's own count (which undercounts quiet playback), and
opens and switches are derived from app changes. Vouching for all six with one sentence was a
precision over-claim on three of them.

### The unknown state (EVO-014 on a new surface)

`denied` and `unavailable` each render the shared `PermissionCard` — `denied` with a **Grant**
action wired to `sl<PermissionRepository>().request(AppPermission.usageAccess)` (the
`rules_screen` precedent), `unavailable` with `unknown: true` so it reads the neutral "Checking…" row, plus **Retry** —
which required `PermissionCard` to render an action in its unknown state at all (it previously
dropped it, so this button was dead code that this doc described as working). **Neither ever renders `0 m`**, because that is indistinguishable from a
genuinely quiet day. A genuinely quiet day is a separate, granted state and says
"Nothing recorded yet today".

### Entry point — the Activity tab

`analytics_screen.dart`'s `_ActivityBody` became stateful and gained a `GlassSegmented`
**Insights | Events** control; Insights is the default segment, and the reel counter card plus the
block-event feed stay on Events exactly as before. `_withCubit` is now a `MultiBlocProvider`
supplying both `AnalyticsCubit` and `InsightsCubit`. The list is wrapped in a `RefreshIndicator`
with `AlwaysScrollableScrollPhysics`, so pull-to-refresh works even on the short permission-card
page.

**No new route, no new nav entry, no dashboard tile** — the Activity tab is already a nav
destination, so a dashboard tile would only have switched tabs.

### Accessibility

`StatCard` announces one merged sentence (`"Pickups: 84"`) instead of two loose nodes, and honours
"remove animations" — its count-up used to churn the semantics tree on every frame, the exact
thing `ReelCounterCard` wraps in `excludeSemantics`. The hero number announces once; each top-app
row is a labelled button (`"Instagram, 1h 10m. Set a daily limit"`) with `ExcludeSemantics` **inside**
the tappable, so the row keeps its tap action. The proportion bar is the shared `ProgressBar`,
which takes an optional `semanticLabel` because a bare bar contributes no semantics node at all.

## 7. Channel & permission delta

**None.** M4 adds no command method, no event type and no permission. It consumes M0.2's
`queryAppUsage` / `queryUsageEvents` and the existing `contentCounterSnapshot`
([18](18-platform-channel-contracts.md) is unchanged by this feature).

## 8. Honesty & privacy

- `UsageStatsManager` foreground time includes a **visible-but-idle** app. That is the same number
  the OS shows in Digital Wellbeing, which is the right bar — the footnote says so rather than the
  code quietly "improving" it.
- Per-app usage is sensitive. It stays on device, is written only to the local Hive box, and is
  **never** sent to Firebase — the telemetry layer ([19](19-firebase-telemetry.md)) has no insights
  events. The data-safety answers in [22](22-play-release.md) must be re-checked before the next
  release: the existing accessibility disclosure ("your counts and settings stay on your device")
  now covers materially more data.
- **No premium gate.** Premium is a local dev-unlock; gating the honest-numbers feature would
  undercut the product's own argument.

## 9. Tests

- `test/insights_compute_test.dart` (20) — the pure fold: empty input → zero stats with null pickup
  timestamps; repeated same-app foregrounds → 0 switches; a single event → 0 switches;
  `A, A, B, A` → 2 switches and 2 opens of A; a pickup interleaved in a foreground run does not
  mint a second open; out-of-order events sorted, never negative; an event exactly at `start` kept
  and exactly at `end` dropped; a zero-foreground app absent from `topApps`; an uncatalogued app
  counted as screen time but never as distraction; `topApps` descending and capped at ten; a JSON
  round trip; a partial document read as zeros.
- `test/insights_rollup_test.dart` (14) — the store: today `complete: false` and yesterday
  backfilled `complete: true` exactly once; midnight answers without querying; a reel-count failure
  degrades to 0; `UsageDenied` never becomes an empty day and never falls back to cache;
  `UsageUnavailable` serves a cached today or stays unavailable; 91 days prune to 90 dropping the
  oldest; pruning chronological, not insertion-ordered; a corrupt blob treated as empty; every
  persisted key matches `dd-MM-yyyy`; a protected app is absent from `topApps` **and** from the
  written document while still counting toward the aggregate; a user's own protected addition is
  excluded too, and an unreadable protected store still hides the catalog; a backwards clock never
  downgrades a finished day; the midnight fast path still reports a missing grant as denied.
- `test/insights_cubit_test.dart` (11) — a throwing repository lands on `unavailable` rather than
  a stuck spinner; `load()` never throws, so the unawaited resume leg is safe; closing during the
  installed-apps scan does not throw; the numbers emit before the labels; a stale `yesterday` is
  dropped on a rollover rather than relabelled; `refreshIfStale` is a no-op within a day, recomputes
  across one, and re-checks a previously denied grant; concurrent refreshes coalesce.
- `test/insights_view_test.dart` (8) — denied offers Grant and prints no zero; unavailable renders
  the neutral state **and a Retry that actually recomputes**; granted draws `3h 12m` and the
  footnote; a quiet day says so instead of showing the denied card; a complete yesterday shows as a
  neutral reference and an incomplete one is not shown at all; a top-app row is labelled, timed and
  exposed as a button.

## Source files

- `lib/features/analytics/insights/domain/entities/daily_stats.dart`
- `lib/features/analytics/insights/domain/usecases/compute_daily_stats.dart`
- `lib/features/analytics/insights/domain/repositories/insights_repository.dart`
- `lib/features/analytics/insights/data/repositories/insights_repository_impl.dart`
- `lib/features/analytics/insights/presentation/insights_state.dart`
- `lib/features/analytics/insights/presentation/insights_cubit.dart`
- `lib/features/analytics/insights/presentation/widgets/insights_view.dart`
- `lib/features/analytics/analytics.dart` (barrel)
- `lib/features/analytics/presentation/analytics_screen.dart` (the segmented entry point)
- `lib/core/storage/local_store.dart` (`StoreKeys.usageDaily`)
- `lib/core/utils/duration_format.dart` (`formatHm` — the app's one duration form, shared with the
  dashboard hero and the onboarding dial, mirrored by Kotlin `UsageQuery.formatHm`)
- `lib/features/limits/rules/domain/entities/rule_editor_args.dart` (moved out of `presentation/`
  for EVO-033)
- `lib/core/di/injector.dart`
- `test/insights_compute_test.dart`, `test/insights_rollup_test.dart`,
  `test/insights_view_test.dart`, `test/insights_cubit_test.dart`
