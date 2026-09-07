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
| `screenTimeMs` | Σ `foregroundMillis` over rows **clipped to the window length** — `queryAndAggregateUsageStats` returns bucket totals that are not clipped to the window, so a short post-midnight window could carry most of yesterday's bucket into a multi-hour "today"; non-positive rows dropped (native already drops them) |
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
testable without waiting for midnight. Registered in `injector.dart` as a lazy singleton, like
every repository.

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
   partial one**, which is what a device clock moved backwards produces. Every write also
   **scrubs the current protected set from every stored day's `topApps`** (`_scrubProtected`):
   only today and an unfinished yesterday are ever recomputed, so a package protected *today*
   would otherwise stay named under every already-complete day for up to 90 days.

The document is decoded **once** per `today()` and threaded through the backfill and the write,
and the decoded map is memoised against the exact raw string it came from: the cubit reads
`cached()` right after `today()` decoded the same document, which used to parse all 90 days a
second time. A wipe or any outside write changes the string, so the memo can never serve a stale
document (pinned by the rollup test).

Grant handling is the whole reason the return type is `UsageQueryResult<DailyStats>`:

| Case | Answer |
|---|---|
| granted | `UsageGranted(stats)` |
| `UsageDenied` | `UsageDenied` — **never** a cached fallback and never an empty day. A stale figure presented as live is the same lie as `0 m`. |
| `UsageUnavailable` | today's cached record if one exists (the engine failed, but that number was real) — scrubbed of the current protected set in memory first, because only the granted exit's write scrubs and the screen names `topApps` from this record ([24](24-protected-apps.md) §6) — otherwise `UsageUnavailable` |

`cached(dayKey)` is synchronous because `LocalStore.read` is. `hasAccess()` proxies the usage
layer's tri-state grant read for the cubit's resume path (§6).

Every recompute also reads `protectedPackagesFor(ProtectedAppsRepository.load())` and passes it
to the fold. A failed read degrades to the **bundled catalog** rather than to an empty set, so
the seeded banking / UPI / password-manager packages stay hidden either way.

## 6. Presentation

`InsightsCubit(InsightsRepository, EngineRepository, {clock})` over
`InsightsState { status, stats, yesterday, apps }` with
`enum InsightsStatus { loading, granted, denied, unavailable }`.

- `load()` / `refresh()` / `refreshIfStale()` — the last recomputes when the cached `dayKey` has
  gone stale (a session held across midnight) **or when the grant was revoked in Settings while
  the app was away**: one `hasAccess()` read, a recompute only on an explicit `false` (`null` =
  could not read). The day key alone let a revoked grant keep numbers on screen as if live.
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
- `apps` maps package → `InstalledApp` for **every** installed app, from
  `EngineRepository.installedApps()` (already process-cached), resolved on every compute
  **whatever the grant said** — it labels the By app section's reels and blocks rows too, which need
  no permission, and it is the Activity screen's one lookup, so pull-to-refresh renews labels.
  A failure costs the labels, not the numbers: rows fall back to the package name and the last
  good map stays.

`InsightsView` is a `StatefulWidget` + `WidgetsBindingObserver` for that resume hook, and calls
`refresh()` on every mount. **No ticker, no stream, no background job.** Since EVO-058 the cubit
is provided app-wide in `main.dart` — but **lazily**, so nothing is computed at boot: the first
Activity open constructs it. The shell rebuilds the tab on every switch and the drawer pushes a
second route over it, so one shared instance means a later open paints the last numbers at once
and refreshes in place, instead of flashing a spinner and running two channel queries per mount
(or two concurrent computes racing on `usage_daily` from the drawer). `AppResumeSync` is
untouched.

What `InsightsView` itself draws is the **Distraction** section: a `SectionHeader('Distraction')`
in every state — its header row also carrying the screen's one `IconButton` (tooltip "About these
numbers", 48 dp), which opens the source note as a `GlassBottomSheet` (`_showAboutSheet`, same
file) — over one `GlassCard` panel (`_DistractionCard`) when granted — the distracting share as a
shared `ProgressBar` with its caption (`"1h 48m · 56% of screen time"` — a share of screen time,
which is what `distractionShare` is — or `"Nothing yet today"`), a content-aligned hairline, then two flat
`StatCard(compact: true, contained: false)` tiles (app switches, distracting opens). The `loading`
state is the `LoadingState` spinner inside a panel of its own, so the section keeps its height
while the numbers arrive. The headline figures live in the Activity screen's **Today** panel
(`TodayOverview`, `analytics/presentation/widgets/today_overview.dart`): **Screen time**
(`formatHm`, yesterday's finished total as a plain `"Yesterday: 4h"` caption) and **Pickups**
(`"First 7:12"` caption — one reference per tile) sit under Detoxo's own **Reels** and **Blocked**
tiles, and appear only when the status is `granted`. The top five apps are the **Time** segment
of the **By app** section (`ByAppSection`, `widgets/by_app_section.dart`), also only when granted.
Both widgets read the same app-wide cubit, so nothing is a second snapshot of a live number. There
is no footnote under the sections: the source note lives behind the info button (above).

**No percentage against yesterday** (EVO-035). Today is still running, so a percentage against
yesterday's *whole* day rendered "95% less than yesterday" every morning — true arithmetic, false
statement. `screenTimeDeltaPercent` now requires both days complete, so it is null on the live
screen and available to a future history view.

**Each top-app row opens a pre-filled daily-limit rule** (EVO-033) — `Routes.ruleEditor` with
`RuleEditorArgs(kind: timeLimit, ...)`, never a silent save. This is the one place the screen
stops being a report: seeing "1h 10m" against an app is the moment a limit gets set. It is why
`RuleEditorArgs` lives in `limits/rules/domain/` rather than `presentation/`. The row is the shared
`AppLimitRow` (`analytics/presentation/widgets/app_limit_row.dart`), the one row for all three
**By app** segments — reels, blocks (EVO-059), time; its label is trimmed so a blank launcher
label falls back to the row's own `name` (the reel counter's display name) and then the package
name instead of a blank row and a rule named `"Limit  "`, and it takes an `iconUrl` for rows that
carry an asset icon rather than installed-app bytes.

The **About these numbers** sheet is scoped to what Android actually produced: screen time,
distraction time and the app list are OS figures; opens and switches are derived from app changes;
reels and blocks (both drawn above this view) are Detoxo's own counts, and reels undercount quiet
playback. Vouching for all of them with one sentence was a precision over-claim on half of them.
It is four short paragraphs of static text — it no longer reads the cubit (the "Today is still
running" line went with the on-screen footnote).

### The unknown state (EVO-014 on a new surface)

`denied` and `unavailable` each render the shared `PermissionCard` under the same **Distraction**
header, so the section keeps its heading with or without numbers — a one-sentence `why`
("Needed to show your screen time." / "Couldn't read your screen time.") and nothing under the
card — `denied` with a **Grant**
action wired to `sl<PermissionRepository>().request(AppPermission.usageAccess)` (the
`rules_screen` precedent), `unavailable` with `unknown: true` so it reads the neutral "Checking…" row, plus **Retry** —
which required `PermissionCard` to render an action in its unknown state at all (it previously
dropped it, so this button was dead code that this doc described as working). **Neither ever renders `0 m`**, because that is indistinguishable from a
genuinely quiet day. A genuinely quiet day is a separate, granted state and says
"Nothing yet today".

### Entry point — the Activity tab

`analytics_screen.dart` is **one scroll of three headed sections** — an uppercase `SectionHeader`
(`lib/core/design_system/components/section_header.dart`, the Settings / Rules grouped-list idiom) over **one**
`GlassCard` panel each — then the override card. Each section widget owns its
header, so the headers carry the vertical rhythm (`md` above, `sm` below) and `_ActivityBody`,
which is stateless, places nothing between them; on the pushed route the list has no top inset
of its own, the app bar and the first header supply it. Top to bottom:

1. **Today** — `TodayOverview`: a 2×2 grid of flat `StatCard(compact: true, contained: false)`
   tiles in one panel, with a content-aligned hairline (`Divider`, `context.glass.border`,
   `indent: sm`) between the rows. **Reels** (live from the app-wide `ContentCounterCubit`,
   `All time: N` caption) and **Blocked** (the app-wide `ServiceCubit`'s native counters via
   `context.select`; one reference — `Yesterday: N` once there is history, `All time: N` before —
   [12](12-analytics-notifications-resilience.md) §1) always; **Screen time** and **Pickups** join
   them, hairline included, once Usage access is granted. Rows are `IntrinsicHeight`
   (`StatCardPair`) so a wrapped caption at a large text scale stretches both tiles.
2. **Distraction** — `InsightsView` (above): the share bar and its two counts in a panel, or the
   permission / loading panel in its place, under the same header in every state. Detoxo's own
   counts lead because they never need a permission — a user without Usage access still gets real
   numbers above the Grant card.
3. **By app** — `ByAppSection`: a `GlassSegmented` **Reels | Blocks | Time** (Time only when
   granted; the index clamps if a grant is revoked from under it) sits bare between the header and
   the panel, `AppSpacing.lg` above it — the control is the one glass surface that casts a shadow,
   the card around it used to clip that, and a narrower gap would let the panel's backdrop blur
   smear it across the rim. The panel is one list of `AppLimitRow`s, busiest first with bars
   relative to the busiest, each row an `AppPressable` (press scale, haptic, focus ring — the app's
   one custom-tappable idiom, never a raw `InkWell`) at least 48 dp tall (`vertical:
   AppSpacing.xs`). The rows are the
   pure, static `ByAppSection.rowsFor(segment, count:, blocks:, stats:)` — sort, top-five cap for
   Time, bar normalisation with the zero guard — dispatched on the `ByAppSegment` enum, never a
   positional index (`test/by_app_rows_test.dart`). Labels for all three come from
   `InsightsState.apps`, the screen's one lookup (below). Every segment is *today* — the block
   tally is native and rolled at read time. An empty segment says why in one muted sentence
   (`ByAppSection.emptyCopy`, one sentence each: "Counting is off. Turn it on under Appearance." /
   "No reels counted yet." / "No blocks yet today." / "Nothing yet today."). The state is kept alive
   (`AutomaticKeepAliveClientMixin`), as is `InsightsView`'s: the `ListView` is lazy, and a section
   scrolled past the cache extent would otherwise lose its chosen segment or re-run the mount
   refresh on the way back.
4. **Overrides** — `OverrideHistoryCard` (EVO-052, hides itself at zero), after an `md` gap.

Twelve glass surfaces on a granted scroll became four (three panels and the segmented control):
the tiles no longer paint glass inside glass, and `SectionHeader` is a `Semantics(header: true)`
node, so TalkBack's swipe-by-heading lands on each section as it did on the `AppCard` titles this
replaced (`test/activity_screen_test.dart` pins the heading and the one-`GlassContainer`-per-section
rule). Those four titled `AppCard`s had themselves replaced three per-app lists in three styles
(the reel card's own rows, "Where it happened", "Where it went"), two hero cards and four loose
`StatCard`s. The `ReelCounterCard` hero is gone with its Today / All toggle; the all-time reel
total is the tile's caption. No provider of its own: `InsightsCubit` comes from `main.dart`
(EVO-058, above). The list is a `RefreshIndicator` with `AlwaysScrollableScrollPhysics`; the pull
recomputes insights **and** re-reads the block counters (error-guarded, the resume path's rule),
because native rolls `today` over at read time and a session pulled across midnight may see no
`blocked` event. The reel tile is stream-fed and already live. The tab header's feedback + menu
pair is the Dashboard header's, gap included, with `DrawerMenuButton` a design-system component.

This replaced a `GlassSegmented` **Insights | Events** control whose Events segment listed one
tile per block from a Dart-side buffer (`AnalyticsCubit`) that only recorded while the tab was
open — the buffer and its feed are gone, see [12](12-analytics-notifications-resilience.md) §1.1.

**No new route, no new nav entry, no dashboard tile** — the Activity tab is already a nav
destination, so a dashboard tile would only have switched tabs.

### Accessibility

`StatCard` announces one merged sentence (`"Screen time: 3h 12m, Yesterday: 4h"`,
`"Pickups: 84, First 7:12"`, `"Blocked: 12, Yesterday: 52"` — the visual "·" is spoken as a comma, since TalkBack
renders U+00B7 as silence) instead of loose nodes, and honours "remove animations" —
its count-up used to churn the semantics tree on every frame; a `text` figure is never animated.
The Distraction card's bar and caption are **one spoken sentence** (`"1h 48m, 56 percent of
screen time"`, derived from the visible line) rather than a bare progress node followed by a raw
"·"; the header's info button announces as "About these numbers". Each **By app**
row is a labelled button (`"Instagram, 1h 10m. Set a daily limit"`, `"Instagram, 9 blocks. …"`)
with `ExcludeSemantics` **inside** the tappable, so the row keeps its tap action. The proportion
bar is the shared `ProgressBar`, which takes an optional `semanticLabel` because a bare bar
contributes no semantics node at all.

## 7. Channel & permission delta

**None.** M4 adds no command method, no event type and no permission. It consumes M0.2's
`queryAppUsage` / `queryUsageEvents` and the existing `contentCounterSnapshot`
([18](18-platform-channel-contracts.md) is unchanged by this feature).

## 8. Honesty & privacy

- `UsageStatsManager` foreground time includes a **visible-but-idle** app. That is the same number
  the OS shows in Digital Wellbeing, which is the right bar — the About sheet says so rather than the
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
  round trip; a partial document read as zeros; negative values floor at zero and `topApps` is
  re-sorted on read; a row longer than the window is clipped to it and rows inside are untouched.
- `test/insights_rollup_test.dart` (14) — the store: today `complete: false` and yesterday
  backfilled `complete: true` exactly once; midnight answers without querying; a reel-count failure
  degrades to 0; `UsageDenied` never becomes an empty day and never falls back to cache;
  `UsageUnavailable` serves a cached today or stays unavailable; 91 days prune to 90 dropping the
  oldest; pruning chronological, not insertion-ordered; a corrupt blob treated as empty; every
  persisted key matches `dd-MM-yyyy`; a protected app is absent from `topApps` **and** from the
  written document while still counting toward the aggregate; a user's own protected addition is
  excluded too, and an unreadable protected store still hides the catalog; a backwards clock never
  downgrades a finished day; the midnight fast path still reports a missing grant as denied; a
  package protected after the fact is scrubbed from every stored day; the decode memo never masks
  a wipe or an outside write.
- `test/insights_cubit_test.dart` (12) — a throwing repository lands on `unavailable` rather than
  a stuck spinner; `load()` never throws, so the unawaited resume leg is safe; closing during the
  installed-apps scan does not throw; the numbers emit before the labels; a stale `yesterday` is
  dropped on a rollover rather than relabelled; `refreshIfStale` recomputes across a day, re-checks
  a previously denied grant, and within a day recomputes only when the grant reads `false` (a
  `null` read is not a revocation); concurrent refreshes coalesce.
- `test/insights_view_test.dart` (7) — denied offers Grant and prints no zero; unavailable renders
  the neutral state **and a Retry that actually recomputes** (the Distraction card appears); granted
  draws the distracting line and the switches / opens tiles, and neither `3h 12m` nor a **Reels**
  tile (those are the Today grid's); a quiet day says so instead of showing the denied card; the
  info button opens the About sheet with the Digital Wellbeing note; a later mount over the same
  cubit shows the card on its first frame, never the spinner (EVO-058).
- `test/activity_screen_test.dart` (5) — the Activity screen over real cubits and fakes in `sl`
  (the `web_block_screen_semantics_test` idiom): a native status event lands in the Blocked tile
  (`"Blocked: 12, Yesterday: 52"`) and, behind the Blocks segment, the per-app
  rows (most-blocked first, each a button offering a limit); the scroll reads Today → Distraction →
  By app with `1h` on screen and the info button in place of a footnote; a fresh install claims no
  yesterday; without Usage access the OS tiles and the Time segment are absent; a complete
  yesterday reads as `Yesterday: 4h`, pickups carry their first-pickup caption, and the Time
  segment's top app is
  labelled, timed and exposed as a button.

## Source files

- `lib/features/analytics/insights/domain/entities/daily_stats.dart`
- `lib/features/analytics/insights/domain/usecases/compute_daily_stats.dart`
- `lib/features/analytics/insights/domain/repositories/insights_repository.dart`
- `lib/features/analytics/insights/data/repositories/insights_repository_impl.dart`
- `lib/features/analytics/insights/presentation/insights_state.dart`
- `lib/features/analytics/insights/presentation/insights_cubit.dart`
- `lib/features/analytics/insights/presentation/widgets/insights_view.dart`
- `lib/features/analytics/analytics.dart` (barrel)
- `lib/features/analytics/presentation/analytics_screen.dart` (the Activity screen: the three
  headed sections this view sits second in)
- `lib/features/analytics/presentation/widgets/today_overview.dart` (the Today panel: reels,
  blocks, screen time, pickups as flat tiles)
- `lib/features/analytics/presentation/widgets/by_app_section.dart` (the By app section: Reels |
  Blocks | Time over one panel of one row type)
- `lib/features/analytics/presentation/widgets/app_limit_row.dart` (the shared per-app row)
- `lib/core/design_system/components/section_header.dart` (`SectionHeader` — the section headers,
  semantic headings; re-exported from `core/widgets/common_widgets.dart` for its older importers)
- `lib/core/design_system/components/cards.dart` (`StatCard.contained`, `GlassCard`)
- `lib/main.dart` (the lazy, app-wide `InsightsCubit` provider — EVO-058)
- `test/activity_screen_test.dart`
- `lib/core/storage/local_store.dart` (`StoreKeys.usageDaily`)
- `lib/core/utils/duration_format.dart` (`formatHm` — the app's one duration form, shared with the
  dashboard hero and the onboarding dial, mirrored by Kotlin `UsageQuery.formatHm`)
- `lib/features/limits/rules/domain/entities/rule_editor_args.dart` (moved out of `presentation/`
  for EVO-033)
- `lib/core/di/injector.dart`
- `test/insights_compute_test.dart`, `test/insights_rollup_test.dart`,
  `test/insights_view_test.dart`, `test/insights_cubit_test.dart`
