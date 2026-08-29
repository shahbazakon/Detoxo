# M4 — Insights: real screen time and honest metrics

- Status: **shipped** — engineering doc [`code_docs/28-insights.md`](../code_docs/28-insights.md); on branch `sensitive_protection` (commit pending at the time of writing).
- Shipped with these deviations from the plan below (each decided against the real code, see the engineering doc): **`unblockCount` is not implemented** — its source is the `temporaryUnblocks` grant ledger, which belongs to the unshipped M2/M8, and a field that is structurally always `0` would be a lie in the store; **`distractionOpens` uses foreground-*transition* semantics** via the existing `countOpens`, not the plan's raw event count, so insights, the rules limiter and native `UsageQuery.countOpens` all mean one thing by "an open"; **`contextSwitches` is derived** as `Σ countOpens − 1` rather than a second walk, which *is* the `prevPkg != null` guard with no room to drift; **`foldSlices` was not written** (its only consumers would be M7 and a per-app timeline, neither shipped); **no new widgets for `metric_card` / `usage_unknown_card` / `app_usage_slice`** — `StatCard`, `PermissionCard` and `AppUsage` already were those things; **no `/insights` route and no dashboard tile** — the screen is the default segment of a `GlassSegmented` **Insights | Events** control in the Activity tab, which is already a nav destination; **the 90-day history UI and step 6 (the counter/UsageStats reconciliation) are deferred** — the rollup store ships and accumulates, but nothing charts it yet and `ContentCounter.kt`'s ceiling comment is untouched because it has not been *measured*; **backfill covers yesterday only**, which is what the previous-day comparison reads; and `formatHm` was promoted out of `dashboard_tab.dart` into `lib/core/utils/duration_format.dart` rather than copied.
- Source: [D1 Stats & Insights](../suggestion_docs/flutter-migration/D-insights-engagement/D1-stats-insights.md) · day-boundary dedupe from [E3](../suggestion_docs/flutter-migration/E-platform-growth/E3-heartbeat-and-daily-active.md)
- Feature areas: `lib/features/analytics/insights/` (extends the existing analytics feature)
- Effort: **M** (one pure function, one rollup store, one screen; the native half ships in M0.2)
- Blocked by: M0 · Blocks: nothing

About 95 % of D1 is local and directly usable. What is dropped is the thin remainder.

## Why now

Every time number in Detoxo today is **inferred from gaps between accessibility events**. The
counter accrues usage only while events keep arriving within `USAGE_ACTIVE_GAP_MS` (12 s); a longer
gap is treated as "screen off or away". The code states the consequence itself at
[`engine/ContentCounter.kt:170`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt#L170):

> `ponytail: active-event heuristic — undercounts truly passive, event-quiet playback.`

Which is precisely the case the product exists for. A user watching a 60-second reel without
touching the screen generates almost no events; the app under-reports exactly the behaviour it is
trying to make visible. Meanwhile the phone's own `UsageStatsManager` has the correct number and
Detoxo already holds the permission to read it (M0.2).

The second gap is scope. `cc_time_today` / `cc_time_total` are the only time series that exist —
no per-day history, no weekly view, no comparison, no pickups, no "how much of my screen time was
distraction". The product's promise is awareness; the evidence for it is two integers.

## What the user gets

A daily insights view that answers the questions the counter cannot:

- **Screen time** — total, and per app, matching the phone's own figure.
- **Distraction time** — how much of it was on `distracting` apps (M0.1's catalog), and how many
  times a distracting app was opened.
- **Pickups** — how many times the device was woken, and the first and last of the day.
- **Context switches** — how often attention jumped between apps.
- **Reels in context** — the existing count, now expressible as a share of screen time.
- **History** — the last 90 days, with no Pro gate.

## Source: what is taken, what is dropped

**Taken** — the whole `computeDailyStats` fold, the `[ts, nextTs)` context aggregation, the pure
use-case structure, and the day-rollup cache.

**Dropped** — `StatsSyncRepository`'s four nullable fields (sleep, sleepConsistency,
firstHourAwake, weather): all backend- or Health-derived, and D1 itself ships a
`LocalOnlyStatsSyncRepository` returning nulls. Also dropped: the `pedometer` step counter,
`sensors_plus`, the B5 sensor context classifier (whose thresholds are bytecode-only and
unrecoverable — see [M7](08-M7-soft-nudge.md)), and the RevenueCat `isPro` history gate.

## Algorithm & control flow

The core is a **pure function with zero platform imports**, unit-testable with no device. That
property is worth protecting deliberately: it means every metric below can be tested against a
handcrafted event list in milliseconds, which is the only practical way to be confident about
figures a user will compare against Digital Wellbeing.

```
computeDailyStats(usage, events, unblocks, catalog, startMs, endMs) -> DailyStats
    // window convention is [startMs, endMs) over the LOCAL day

    screenTimeMs      = Σ usage.foregroundMillis

    distractionMs     = Σ usage.foregroundMillis
                          where catalog.behaviorForPackage(pkg) == distracting
    distractionOpens  = count events where type == moveToForeground
                          && catalog.behaviorForPackage(pkg) == distracting

    pickups           = events where type == screenInteractive          // type 18
    pickupCount       = pickups.length
    firstPickupMs     = pickups.minBy(ts)?.ts
    lastPickupMs      = pickups.maxBy(ts)?.ts

    contextSwitches:
        prevPkg = null; n = 0
        for e in events where type == moveToForeground, ordered by ts:
            if (prevPkg != null && e.package != prevPkg) n++
            prevPkg = e.package
        // repeated foregrounds of the SAME app do not count as a switch
        return n

    unblockCount      = count grants where startMs ∈ [start, end)
                          && (cancelledMs == null || cancelledMs >= start)

    topApps           = usage sorted by foregroundMillis desc, take 10
```

Two details that look like nits and are not:

- **`prevPkg != null`** guards the first event, so a day's first app open is not counted as a
  switch away from nothing.
- **The unblock predicate** counts a grant that *started* in the window even if it was cancelled
  during it, but not one cancelled before the window opened — so "I unblocked 4 times today" stays
  true after an early cancel.

### Time-slice fold (for any interval series)

Reused by M7's session accounting and by the per-app timeline:

```
foldSlices(events, endMs):
    sort by ts
    for i in events.indices:
        sliceEnd = (i + 1 < events.length) ? events[i+1].ts : endMs
        slice    = max(0, sliceEnd - events[i].ts)        // clamp negatives, never trust order
        acc[events[i].key] += slice
        if (i > 0 && events[i].key != events[i-1].key) transitions++
    dominant = acc.entries.maxBy(value)?.key
    // empty input -> zero stats, never null-deref
```

### Day boundary

E3's one genuinely portable idea: **pick a single canonical day boundary and dedupe on it.** E3
used a fixed `America/Los_Angeles`; that is wrong for a device-local product, so Detoxo uses the
**device local day**, but the discipline is the same — one definition, used everywhere.

The concrete hazard here is already live in the repo: native `DateKeys` and Dart `daySignature()`
both use `dd-MM-yyyy`, but `WebBlockStatsRepositoryImpl._todayKey()` uses `yyyy-MM-dd`. Two formats
for the same concept in one app. **Every day key introduced by this plan uses `dd-MM-yyyy`**, and
the web-blocker mismatch is noted in [09](09-contracts-and-storage.md) as a separate cleanup.

### Refresh policy

Pull-only, matching M0.2. Recompute on: insights screen open, pull-to-refresh, and app resume when
the cached day key is stale. **No ticker, no background job, no stream.** A day's compute is one
`queryAppUsage` + one `queryUsageEvents` + an O(n) fold over a few hundred events — cheap enough
that caching is for offline reads and history, not for performance.

### Truthful unknown

Usage Access is **optional** in the funnel. When it is not granted, the screen must say so and
offer the grant — never render `0 m`, which is indistinguishable from a genuinely quiet day and
would be a confident lie. This is EVO-014's rule, applied to a new surface.

## Data model

Hive, key `StoreKeys.usageDaily`. One document, day-keyed, **90-day cap with prune on write**:

```jsonc
{
  "days": {
    "02-09-2026": {
      "screenTimeMs": 11520000,
      "distractionMs": 6480000,
      "distractionOpens": 37,
      "pickupCount": 84,
      "firstPickupMs": 1756789200000,
      "lastPickupMs":  1756860000000,
      "contextSwitches": 142,
      "unblockCount": 3,
      "reelCount": 96,
      "topApps": [ { "package": "com.instagram.android", "ms": 4200000 } ],
      "computedAtMs": 1756860300000,
      "complete": true          // false while it is still today
    }
  }
}
```

`complete: false` for the current day matters: a partial day must never be charted as if it were a
finished one, or every "today vs average" comparison reads low until bedtime.

Retention is bounded because Hive holds this as a single JSON document — 90 small day records is a
few tens of KB, which is fine; unbounded growth would not be.
`ponytail: one JSON doc rewritten per recompute; at 90 days that is fine, at 3 years it is not.
Upgrade path = per-day keys or a real store.`

## Channel delta

**None of its own.** M4 consumes M0.2's `queryAppUsage` and `queryUsageEvents`, and the existing
`contentCounterSnapshot` for reel counts.

## Module layout

```
lib/features/analytics/insights/
├── domain/entities/{daily_stats,app_usage_slice,insights_state}.dart
├── domain/repositories/insights_repository.dart
├── domain/usecases/compute_daily_stats.dart      # PURE — zero platform imports
├── data/repositories/insights_repository_impl.dart
└── presentation/{insights_cubit.dart, insights_screen.dart,
                 widgets/{metric_card,pickup_timeline,top_apps_list,usage_unknown_card}.dart}
```

Lives **inside the existing `lib/features/analytics/` feature** and is exported from its existing
`analytics.dart` barrel. It is the same concern — showing the user their own behaviour — and a
second top-level feature would need a second barrel and invite a boundary violation.

## Reuse map

| Existing | Take |
|---|---|
| `StreakCubit.advance` | The pure static method + `bloc_test` pattern that `compute_daily_stats` follows |
| `AnalyticsCubit` / `AnalyticsScreen` | The existing "Activity" feed and its section layout; insights is a second tab or section, not a rival screen |
| `WebBlockStatsRepositoryImpl` | The existing stats-dashboard shape (blocked today / total / focus minutes saved / most-blocked host) — same visual language |
| `lib/core/utils/day_signature.dart` | The `dd-MM-yyyy` helper. **Use it; do not add a third format** |
| `engine/UsageLadder.kt` ↔ `usage_ladder.dart` | The byte-identical mirror pattern, if insights adopts the usage tint |
| `lib/core/design_system/components/cards.dart` | `metric_card` |
| EVO-014's unknown-state rendering | `usage_unknown_card` |
| `intl` (declared) | Duration and date formatting |

## Steps

1. `compute_daily_stats.dart` as a pure function, with its test written first.
2. `DailyStats` entity + the Hive rollup store with the 90-day prune.
3. `InsightsRepository` over M0.2 + M0.1 + the counter snapshot.
4. `InsightsCubit` with `granted | denied | loading | data` states.
5. `InsightsScreen` + widgets; route it from the analytics screen and the dashboard.
6. Reconcile the counter's `timeTodayMs` against real foreground time and surface the delta in
   debug only — this is what retires the `ContentCounter.kt:170` ceiling, and it should be
   *measured* before the ceiling comment is edited.
7. `/docs-sync` — 12, 17, plus `info_docs/02`.

## Risks & ceilings

- `ponytail: one JSON doc rewritten per recompute; fine at 90 days, not at 3 years.`
- `ponytail: rollups recompute on open/resume only; a day closed while the app was never opened is
  backfilled on the next open from UsageStats, which retains ~7 days on most devices. Beyond that
  the day is lost.` — a real limit worth stating in the UI as "history starts here".
- **Do not present usage data as more precise than it is.** `UsageStatsManager` foreground time
  includes a visible-but-idle app; it is the same number the OS shows, which is the right bar.
- **Privacy.** Per-app usage is sensitive. It stays on device, is never sent to Firebase, and the
  data-safety answers in `22-play-release.md` must be re-checked when this ships. The existing
  accessibility disclosure already promises "your counts and settings stay on your device" — that
  promise now covers more data.
- **Do not gate history behind premium.** D1 gates it; Detoxo's premium is a dev-unlock with no
  reader, and gating the honest-numbers feature would undercut the product's own argument.

## Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] `compute_daily_stats` tests: empty input → zero stats, no null-deref; repeated same-app
      foregrounds → 0 switches; a single event → 0 switches; events out of order → clamped, never
      negative; a distracting app with 0 foreground ms → not in `topApps`; boundary events exactly
      at `startMs` and `endMs`
- [ ] Denied Usage Access renders the unknown card, never `0 m`
- [ ] The 90-day prune keeps exactly 90 and drops the oldest
- [ ] `complete: false` for the current day; charts exclude or mark it
- [ ] Device sanity: today's screen time is within a couple of minutes of Settings → Digital
      Wellbeing; pickup count is plausible; reel count matches the bubble
- [ ] `pubspec.yaml` unchanged
- [ ] No new channel method, no new permission

## Target files

**New** — `lib/features/analytics/insights/**` · `test/insights_compute_test.dart` ·
`test/insights_rollup_test.dart`

**Edited** — `lib/core/storage/local_store.dart` (+`StoreKeys.usageDaily`) ·
`lib/core/di/injector.dart` · `lib/features/analytics/analytics.dart` ·
`lib/features/analytics/presentation/analytics_screen.dart` ·
`lib/core/navigation/{routes,app_router}.dart` ·
`lib/features/dashboard/presentation/dashboard_tab.dart`
