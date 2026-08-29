# Content Counter (Reel/Short Counter)

The **content counter** tallies the short-form videos (Reels, Shorts, and other
infinite-feed clips) the user actually watches, and surfaces that number three
ways: an in-app live card, a draggable **floating bubble** overlay, and a
**2×2 home-screen widget**. It is deliberately **decoupled from blocking** — a
side-effect-free counting pass runs *before* the block logic and tallies reels
whether blocking is master-off, paused, or the app/platform is disabled. The
counter is **enabled by default** (awareness-first), independent of whether any
blocking plan is active.

> Blocking, detection, and the accessibility service that hosts this counter are
> covered in [03-detection-engine.md](03-detection-engine.md) and
> [05-plans-pause-conscious.md](05-plans-pause-conscious.md). This doc covers only the counter.

---

## 1. Architecture at a glance

```
AccessibilityService (main process, single thread)
   │  onAccessibilityEvent()
   │     ├─ countContent(event, pkg)      ← runs FIRST, side-effect-free
   │     └─ (block logic, only if masterEnabled & not paused)
   ▼
ContentCounter.kt          fan-out + bubble visibility; owns the one tracker timer
   ├─ ReelTracker.kt           WHEN a distinct reel is counted (page identity + dwell; pure Kotlin, unit-tested)
   ├─ ContentCounterStore.kt   persists to SharedPreferences "detoxo_engine_prefs"
   ├─ ContentCounterBubble.kt  floating overlay (WindowManager)
   └─ ContentCounterWidgetProvider.kt + WidgetBitmapRenderer.kt  home widget
        └─ UsageLadder.kt      shared color/emoji ladders (mirrors Dart)

MethodChannel "com.errorxperts.detoxo/commands"     (pull / toggles / style)
EventChannel  "com.errorxperts.detoxo/events"        contentCounted {...}
   ▼
Dart feature lib/features/content_counter/**
   ├─ content_counter.dart        public barrel (entities, contracts, cubits, card, previews)
   ├─ content_counter_core        ContentCount, cubits, live card, repos
   ├─ content_counter_bubble      BubbleStyle + bubble on/off + overlay perm
   ├─ home_content_counter        WidgetStyle + pin/refresh (command channel)
   └─ content_counter_appearance  Bubble-style + Home-widget editor screens
```

The Dart feature follows the same feature-first Clean Architecture as the rest of
the app (data / domain / presentation, wired via `get_it` locator `sl` in
`lib/core/di/injector.dart`, Cubits only). The **native store is the single
source of truth**: the bubble and widget stay correct even when the Flutter UI is
dead, because the counting brain writes SharedPreferences and pushes the surfaces
directly.

---

## 2. The counting pass (native, independent of blocking)

### 2.1 Where it runs

In `DetoxoAccessibilityService.onAccessibilityEvent`, counting is invoked before
any block gate:

```kotlin
if (pkg == packageName) return
// ── Awareness counting: runs independent of blocking (master-off /
//    paused / platform-disabled) and is strictly side-effect-free ──
if (contentCounter.isEnabled) countContent(event, pkg)
if (!store.masterEnabled) return                 // block path gated AFTER counting
if (System.currentTimeMillis() < store.pauseUntil) return
```

`countContent(...)` **never presses back and never reads or writes block state**.
It reuses the same read-only 3-stage `matches()` view-id search the blocker uses,
but only to answer "is a reel surface on screen right now?". It has its own
per-package throttle (`lastCountEventByPackage`, `COUNT_THROTTLE_MS = 400`,
slower than the block path's 150 ms because a stage-3 miss on a non-reel screen
is a full DFS and nothing about a reel's dwell is anchored to this check;
`TYPE_WINDOW_STATE_CHANGED` bypasses it so reel entry/exit is seen at once).
Scroll events are forwarded **before** that throttle, with the pager's own
`fromIndex` / `toIndex` / `scrollDeltaY` (API 28+) — the reel's identity (§2.3).
Setting `adb shell setprop log.tag.DetoxoService DEBUG` logs the raw scroll
fields per event for per-app calibration; the switch is read once per service
bind (`scrollDebug`), so re-bind the service after setting the property.

**DFS back-off (EVO-021).** On a non-reel screen every check is a miss, and a
miss used to end in the full stage-3 walk. The pass keeps a per-package
consecutive-miss counter (`countMisses`, cycling `0..DFS_SKIP = 4`): the DFS
runs only when it is 0, so on the feed it walks at most every 5th check (2 s)
while stages 1–2 (`findAccessibilityNodeInfosByViewId` under
`flagReportViewIds`) still run every check. A hit and every
`TYPE_WINDOW_STATE_CHANGED` reset it. Shallow results are computed with
`matches(..., deep = false)` and **bypass the per-event memo**, so the block
pass — which never backs off — always gets a full answer.
`ponytail:` a surface only the DFS finds (an id the app's own `Resources`
can't resolve) is seen ≤ 2 s late.

Foreground changes are forwarded separately from `TYPE_WINDOW_STATE_CHANGED`.
The soft keyboard's window emits this event under the IME's own package
(`Settings.Secure.DEFAULT_INPUT_METHOD`), which is **not** a foreground change to
the counter — typing a comment must not suspend the reel:

```kotlin
if (contentCounter.isEnabled && !isImePackage(pkg)) {
    contentCounter.onForegroundChanged(
        pkg,
        !pkgProtected && config.platformsFor(pkg).any { isReelPlatform(it) },
    )
}
```

### 2.2 What counts as a "reel surface" — `isReelPlatform` + `NON_REEL_PLATFORM_IDS`

Counting reuses the pushed `platforms_config.json` (parsed by
`engine/DetectionConfig.kt`; see [03-detection-engine.md](03-detection-engine.md)).
A platform is treated as a countable reel/short surface only when:

1. its `detectionType` is `LEGACY` or `OVERLAY`, **and**
2. it has at least one `FINDBYID` / `VIEWID_RES_NAME` detector, **and**
3. its `platformId` is **not** in `NON_REEL_PLATFORM_IDS`.

The exclusion set keeps feeds, stories, and statuses out of the reel tally
(they are watched content but not "reels"):

```kotlin
private val NON_REEL_PLATFORM_IDS = setOf(
    "ig_feed", "ig_stories", "insta_pro_stories", "insta_pro2_stories",
    "snap_stories", "wa_status", "wab_status",
)
```

Everything else detectable in a supported app is treated as a reel/short.

### 2.3 Distinct-reel rule (settled-page identity + dwell) — `ReelTracker.kt`

The decision lives in `engine/ReelTracker.kt`, a pure-Kotlin state machine
(no Android imports; every call takes a monotonic `now` — `SystemClock.uptimeMillis`
in production: the Handler's own clock, which stops in deep sleep so a phone that
slept mid-reel can't wake up owing a dwell; usage-time deltas use the same clock)
driven by `ContentCounter.kt`, which owns the single `Handler`
runnable (`tickRunnable`, re-armed by `syncTimer()` from `tracker.nextDueAtMs`)
and the fan-out. State mutates only on the service's main thread. Signals:

| Signal | Fired when | Tracker effect |
| --- | --- | --- |
| `onForegroundChanged(pkg, isReelApp)` | window-state change to a new package (never the IME) | `suspend()` — keeps the session, freezes the dwell; a return within `AWAY_EXPIRY_MS = 60s` resumes the same reel, later = fresh session. Hides the bubble unless the new package **is** the session's own app — another reel-capable app's feed included (its non-reel screens are not leave-evidence, so this is the only hide on that path; `onReelSurfaceSeen` re-shows it) |
| `onReelSurfaceSeen(pkg)` | a reel surface is detected on screen | `surfaceSeen()` — starts / resumes / continues the session; clears no-surface evidence; shows the bubble |
| `onNoReelSurface(pkg)` | a monitored app's window was checked and had **no** reel surface (e.g. the feed) | Only for the **session's own app**: `noSurface(pkg)` stamps the reel's end; after `HIDE_GRACE_MS` one runnable hides the bubble **and** `leave()`s the session. Works with the bubble off. Another monitored app's window (a WhatsApp reply — `wa_status` makes WhatsApp a monitored package — or the YouTube feed) is a detour handled by `suspend`, and is ignored here so the return doesn't recount the reel |
| `onScroll(pkg, fromIndex, toIndex, deltaY, isPager)` | `TYPE_VIEW_SCROLLED` in a reel app (pre-throttle) | `scroll()` records the latest snapshot; classified once the burst is quiet for `SCROLL_SETTLE_MS = 300`. `isPager` (EVO-024) is the platform's verdict on the scrolled view when it declares a `pagerViewId` — `false` makes the snapshot an inner scroll whatever its indices; `null` (no id declared, or no event source) classifies as usual |
| `setEnabled(false)` | counter toggled off | `leave()` (the fan-out is gated, nothing lands) |

**Identity.** A reel is `(pkg, session, page)`. `page` comes from the fields a
pager already puts on every scroll event (RecyclerView / ViewPager:
`fromIndex..toIndex` = visible adapter positions), via `ReelTracker.settledPage`:

- `toIndex − fromIndex ≤ 1` → page = `fromIndex`. A pixel-exact pager reports
  `(n, n)`, one with a 1 px peek reports `(n, n+1)` even at rest — both shift by
  one per advance, so `fromIndex` is stable either way. A different page than the
  current reel = **advance** (the dwell anchor is the scroll event time, not the
  settle time); the same page (snap-back) is ignored.
- `toIndex − fromIndex ≥ 2` → a multi-item list (comments, grids) → ignored.
- `fromIndex = −1` (ScrollView / custom view) → ignored in an app whose pager has
  reported pages (a caption expand); otherwise legacy any-scroll = advance,
  debounced by the dwell (unindexed pagers, e.g. Snapchat).
- The entry reel's page is unknown until the first settle: if that settle
  finished moving backwards (`scrollDeltaY < 0`, a forward-peek snap-back) the
  page is learned without advancing.

The system keeps one pending scroll event per service and restarts its 100 ms
timer on each new one, so a fling often delivers only its final snapshot — the
last event of a burst *is* the settled state, and intermediate deltas are lossy
(hence no delta-sum heuristics).

**Counting.** A reel counts once it has been the current page for
`MIN_VIEW_MS = 1000ms` with no leave-evidence — stopped on, not flicked past.
Passive, event-quiet playback counts (there is no staleness check). At tick
time, if `PowerManager.isInteractive` is false the dwell is *paused* (anchor
zeroed, session kept) and resumes from the next `surfaceSeen` after unlock.
Leave-evidence — the next settled page, the first `noSurface` stamp, an app
switch, disable — ends the reel with a belt-and-braces count when it had earned
its dwell (the end time is the first `noSurface` stamp, never the grace expiry).
A per-session `countedPages` set stops a scroll back up from recounting; a
scroll on the way out of reels can't start a countable reel because only a fresh
`surfaceSeen` clears no-surface evidence.

**Ceilings** (`ponytail:` in the file KDoc): a one-or-two-item inner list
settles like a page — on platforms without a `pagerViewId` (EVO-024; with one
declared, scrolls from any other view are ignored as page evidence — no ids are
shipped until device calibration supplies them); unindexed pagers fall back to
any-scroll + debounce; the entry page is guessed as `firstPage − 1`; holding a
*backward* peek for a whole dwell reads as the previous page. Each ≤ 1
phantom/miss per occurrence.

The rule is surfaced to the user as "counts once you've stopped on it for about
a second; flicks, half-swipes and scrolling the comments are ignored, and the
same reel never counts twice" (FAQ, product overview, walkthroughs). The One
Reel allowance keeps its own 2 s "watched" dwell in the service.

Tests: `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/ReelTrackerTest.kt`
(plain JUnit4, 23 timeline scenarios incl. the monitored-detour and
non-pager-scroll cases) —
`cd android && ./gradlew :app:testDebugUnitTest --tests '*ReelTrackerTest*'`
(also run by `bash tool/dev.sh precommit`).

### 2.4 Bubble visibility (positive-evidence hide)

The bubble is **shown** by `onReelSurfaceSeen` and stays up the entire time the
user watches — even during a passive, event-quiet video, because a detection gap
never hides it. It is **hidden only on positive evidence** the user left reels:

- `onNoReelSurface` (a checked window with no reel surface, e.g. the feed) → a
  single graced hide after `HIDE_GRACE_MS = 1500ms` (bridges between-reel
  transitions without flicker); the same runnable ends the reel session, so the
  grace also gates counting and runs whether or not the bubble is showing, or
- `onForegroundChanged` to another real app → immediate hide.

Our own overlay window and system UI are ignored (`TRANSIENT_PKGS`) so the bubble
can never self-toggle into a show/hide loop.

### 2.5 Fan-out on each count

`count(pkg)` does four things:

1. `store.recordCount(pkg, dateKey(), pendingUsageMs)` — **one** prefs edit
   persists the count *and* the batched usage window (so the event's
   `timeTodayMs` includes the accumulated-but-unwritten time) and returns the
   snapshot built from the maps it already parsed. A count used to cost three
   `apply()`s and four JSON parses (usage flush + count + snapshot).
2. Emit the `contentCounted` event on `ServiceEventBus` (see §4).
3. `pushWidget(snapshot)` — throttled to `WIDGET_MIN_INTERVAL_MS = 1000ms` with
   a **trailing flush**: a push inside the window is deferred to the window's
   end (`widgetRunnable`, fresh snapshot), never dropped. Two counts < 1 s apart
   are routine (belt-and-braces at settle + the next dwell), and a dropped last
   push left the widget one reel behind for hours.
4. If the bubble is enabled and visible, `bubble.onCounted(today)` (springy pop).

All timing in `ContentCounter` is `SystemClock.uptimeMillis` (`mono()`); the
wall clock is only read through `DateKeys.today()`, which is memoised per
wall-clock minute (a per-check zone lookup + format was the largest allocation
on the surface-check path).

The emitted `contentCounted` payload also carries `timeTodayMs` (§2.6, §4) and
the real `enabled` / `bubbleEnabled` flags — Dart's stream mapper defaults
missing flags to `true`, which used to corrupt the toggles' state on a streamed
update.

### 2.6 Whole-app usage-time accrual (`onAppActivity`)

Alongside reel counting, the pass tracks **screen time spent in monitored social
apps** — the signal behind the dashboard's screen-time ring and the bubble's
tap-to-reveal-time. It needs **no new Android permission**; it rides the existing
AccessibilityService. `countContent` calls `contentCounter.onAppActivity(pkg)` for
**every** event from a package that has any configured platform (feed / stories /
DMs / reels — deliberately broader than the reel-surface set of §2.2), *before* the
per-package throttle.

`onAppActivity` accrues the gap between consecutive events from the **same**
monitored app, but only when that gap is under `USAGE_ACTIVE_GAP_MS = 12000ms`; a
longer silence (screen off / user away → no events) starts a fresh window and is
not counted, and a switch to a different package restarts the window. Accrued
deltas are **batched in memory** (`pendingUsageMs`) and flushed via
`store.recordUsage(pendingMs, dateKey())` into `cc_time_today` /
`cc_time_total` (§3) at `USAGE_FLUSH_MS = 5000ms`, on app switch, on
protected-app foreground, on every snapshot pull, and on dispose — previously
one SharedPreferences write per accessibility event at scroll frequency.
Ceiling: ≤ 5 s of usage lost on a hard process kill, and a flush straddling
midnight attributes up to the pending window to the wrong day.

> **Known ceiling (`ponytail:`).** This counts active, event-bearing time and
> deliberately **undercounts truly passive, event-quiet playback** (a silent long
> video fires few accessibility events). The documented upgrade path is a 1 Hz
> foreground ticker while a monitored app is front-most (mirroring the Conscious
> accountant).
>
> **This ceiling is still live.** Insights ([28](28-insights.md)) does not fix it
> — it sidesteps it, by reading the OS's own `UsageStatsManager` figure for a
> *different* purpose (whole-device screen time). The two numbers measure
> different things and are both shown: `cc_time_today` is time in monitored
> social apps as the accessibility pass saw it, and insights' `screenTimeMs` is
> every app as Android recorded it. Reconciling the first against the second —
> and only then editing this comment — is deliberately left as separate work.
> Nothing in this section changed.

---

## 3. Persistence — `ContentCounterStore` (`detoxo_engine_prefs`)

`ContentCounterStore.kt` owns storage only (SRP — the *when-to-count* decision is
`ContentCounter`'s). It shares the same `detoxo_engine_prefs` SharedPreferences
file as `engine/ConfigStore.kt`, so the service, `channels/CommandHandler.kt`, and
the widget all read one source of truth. Keys:

| Key | Type | Meaning |
| --- | --- | --- |
| `cc_enabled` | bool (default **true**) | master on/off for counting |
| `cc_bubble_enabled` | bool (default **true**) | may the floating bubble show |
| `cc_bubble_x` / `cc_bubble_y` | int (`-1` = unset) | last bubble position in px |
| `cc_date` | string `dd-MM-yyyy` | day the "today" buckets belong to (shared by counts **and** usage time) |
| `cc_today` | int | today's reel count |
| `cc_total` | int | all-time reel count |
| `cc_time_today` | long (ms) | today's whole-app foreground time in monitored apps (§2.6) |
| `cc_time_total` | long (ms) | all-time whole-app foreground time |
| `cc_per_app_today` | JSON `{pkg:count}` | today per-app breakdown |
| `cc_per_app_total` | JSON `{pkg:count}` | all-time per-app breakdown |
| `cc_bubble_style` | JSON string | persisted `BubbleStyle` (see §6) |
| `cc_widget_style` | JSON string | persisted `WidgetStyle` (see §6) |

> `cc_enabled` / `cc_bubble_enabled` are cached per `ContentCounterStore`
> instance (the service gates every event on `enabled`, so the hot path never
> takes the prefs lock). Safe because every writer also goes through the live
> service's instance: `CommandHandler` writes its own store *and* calls
> `contentCounter.setEnabled` / `setBubbleEnabled`.

**Day rollover** is keyed off the **single shared `cc_date` marker** — the reel
counts and the usage-time buckets roll over together — and is handled two ways:

- **Durable** reset, by whichever writer turns the day over. When the stored
  `cc_date` differs from today, `recordCount` zeroes `cc_today`,
  `cc_per_app_today` **and `cc_time_today`** before its increment; symmetrically
  `recordUsage` (the usage-time writer) zeroes `cc_today` and `cc_per_app_today`
  before adding time. Because `cc_date` gates *both* features, whichever writer
  rolls the day must zero the other feature's today bucket too, or a same-day read
  after that write would return yesterday's value.
- **Read-time** rollover: `snapshot` and `todayCount` (and `timeTodayMs`) report
  `today = 0` / `timeTodayMs = 0` and an empty per-app-today map **without
  writing** when the stored day is stale, so a snapshot pulled just after midnight
  is correct even before the day's first event.

`snapshot(dateKey)` returns the map consumed everywhere:
`{enabled, bubbleEnabled, today, total, date, perAppToday, perAppTotal,
timeTodayMs, timeTotalMs, bubbleStyle, widgetStyle}`.

---

## 4. Platform channel surface

Channels are defined in `lib/core/constants/channel_constants.dart` and wrapped by
`lib/core/platform_channels/engine_channel.dart` (which no-ops off Android via
`PlatformCapabilities`). Commands are handled in `channels/CommandHandler.kt`.

### Commands (MethodChannel `…/commands`)

| Method | Dart wrapper | Native behavior |
| --- | --- | --- |
| `contentCounterSnapshot` | `contentCounterSnapshot()` | prefers the live service's in-memory snapshot; falls back to `ContentCounterStore(context).snapshot(...)` when the service is dead |
| `setContentCounterEnabled` | `setContentCounterEnabled(enabled:)` | writes `store.enabled` **and** calls `contentCounter.setEnabled` on the live service; a missing/malformed `enabled` is a no-op (`false`), never a silent "on" |
| `setContentBubbleEnabled` | `setContentBubbleEnabled(enabled:)` | writes `store.bubbleEnabled` **and** `contentCounter.setBubbleEnabled`; same no-op rule |
| `refreshContentWidget` | `refreshContentWidget()` | `ContentCounterWidgetProvider.pushUpdate(...)` from the store |
| `setCounterStyle` | `setCounterStyle(bubble:, widget:)` | persists only the present style key(s) (`as? Map`, a malformed one is skipped) and live re-renders **only that surface**: `bubble` → `onStyleChanged`, `widget` → every pinned widget |
| `pinContentWidget` | `pinContentWidget()` | `AppWidgetManager.requestPinAppWidget`; returns false if unsupported |

`setCounterStyle` sends only the keys present (`{'bubble': ?bubble, 'widget': ?widget}`),
so a bubble edit doesn't re-push the widget style and vice-versa.

### Event (EventChannel `…/events`, `type = contentCounted`)

Emitted on every counted reel:

```
{ type: "contentCounted", package, today, total, perAppToday, perAppTotal,
  timeTodayMs, enabled, bubbleEnabled }
```

`timeTodayMs` is today's whole-app usage time (§2.6). `enabled` /
`bubbleEnabled` carry the real toggle values because Dart's stream mapper
defaults missing flags to `true`. The `contentCounterSnapshot`
pull reply additionally carries `timeTotalMs`; no new method/event name was added.

`ContentCounterRepositoryImpl.watch()` yields an initial pull, then re-maps each
`contentCounted` event into a `ContentCount` for the live UI.

---

## 5. The two native surfaces

### 5.1 Floating bubble — `overlay/ContentCounterBubble.kt`

- Hosted inside the **existing accessibility service** — no new
  service. All view ops run on the main `Looper`.
- `WindowManager` overlay: `TYPE_APPLICATION_OVERLAY` (API 26+) with a
  `TYPE_PHONE` fallback pre-O; flags `NOT_FOCUSABLE | NOT_TOUCH_MODAL |
  LAYOUT_NO_LIMITS`. **No-ops without `Settings.canDrawOverlays`** — counting
  still works, only the overlay is skipped, and a once-per-process `Log.w`
  ("bubble suppressed: overlay permission missing") leaves a trace so a revoked
  grant doesn't read as "the counter stopped".
- **Steady-state fast path + revoke recovery**: `show()` checks
  `shown && view.isAttachedToWindow` *before* the `canDrawOverlays` binder
  call, so the per-detection IPC is gone while the window is alive — and the
  attach check is what makes a **revoke → re-grant** re-attach the bubble
  instead of updating a detached view forever (the OS removes the window on
  revoke but the fields survive). A detached-but-tracked view is torn down via
  the private `detach()` (shared with `hide()`) before re-adding.
- **Day key**: the bubble's `dateKey()` uses the shared engine
  `DateKeys.today()` (its private `SimpleDateFormat` was the last holdout;
  the shared formatter is timezone-change correct).
- **Draggable + edge-snapping**: drag past touch-slop moves it; on release it
  springs (`ValueAnimator`, 240ms) to the nearest horizontal edge and persists
  `cc_bubble_x/y`. Position is clamped on-screen and restored across shows /
  restarts.
- **Tap gestures (`GestureDetector` alongside the drag handler)** — depend on the
  `showTime` style flag (default on):
  - `showTime` **on**: a **single tap** briefly (`REVEAL_MS = 3000ms`) reveals
    today's watch time (`store.timeTodayMs`) on the bubble as a stopwatch
    (`45s` / `mm:ss` / `hh:mm:ss` — native `formatMs`), then reverts to the
    count; a **double tap** opens the app.
  - `showTime` **off** (legacy): a **single tap** opens the app.
  Drag past slop suppresses the tap, so drag and tap stay mutually exclusive.
- Face is a custom `BubbleView` (Canvas, software layer for the mint glow;
  redraws only on count change). Four variants, parsed from the persisted style
  JSON into a re-clamped `BubbleStyleSpec`:
  `GLASS_ORB` (default), `USAGE_RING`, `EMOJI_MOOD`, `MINIMAL_PILL`.
  `USAGE_RING`/`EMOJI_MOOD`/`MINIMAL_PILL` react to today's count via
  `UsageLadder`. Show/count animations: overshoot pop-in, springy count bump.
- **"Reels left" override (One Reel / Unblock).** `BubbleView` has a
  `remaining: Int?` render mode. While a One Reel / Unblock session is armed the
  bubble shows the **remaining unlockable reels** instead of the today-total:
  when `remaining != null`, `onDraw`/`onMeasure` **override every styled variant**
  (orb/ring/emoji/pill) with a distinct **teal unlock badge** — a circle drawing
  the remaining number over a small "left" caption in the teal accent
  `0xFF3CDDC7`. `ContentCounterBubble.setRemaining(Int?)` stores a `lastRemaining`
  that is **replayed** on view rebuild/show, and `setCount`/`onCounted` still
  update the underlying count so it's correct the instant the session ends and
  `remaining` reverts to `null`. This is a **display-only** coupling — the
  counting brain never changes; only the bubble's face reflects a reel session
  (see §7). Driven from `ContentCounter.setReelSessionRemaining(Int?)` (a
  passthrough gated `if (!store.enabled) return`, so a disabled counter keeps the
  bubble off), which the AccessibilityService calls via `syncReelBubble()` on
  arm / each allowed reel / revert-to-base — see
  [03-detection-engine.md](03-detection-engine.md) §5.3. The bubble's own
  show/hide still honours `bubbleEnabled` and the on-a-reel-surface condition.

### 5.2 Home-screen widget — `widget/ContentCounterWidgetProvider.kt`

- 2×2 `AppWidgetProvider` (config `res/xml/content_counter_widget_info.xml`:
  `minWidth/Height 110dp`, `targetCellWidth/Height 2`, `resizeMode
  horizontal|vertical`, **`updatePeriodMillis="0"`** — no OS self-refresh; the
  counter pushes updates). The **midnight rollover** is repaired by the 15-min
  `receivers/WatchdogJobService.kt` job, which also pushes the widget (no
  wakeups of its own, a no-op when nothing is pinned) — `ponytail:` up to
  15 min of stale "today" after midnight.
- **Single source of truth is `ContentCounterStore`**, so the widget is correct
  even when Flutter is dead. `pushUpdate(context, snapshot)` re-renders every
  pinned instance (cheap no-op when none are pinned); called from the counting
  brain (throttled) and on style changes. `onUpdate` / `onAppWidgetOptionsChanged`
  re-render on add / resize.
- The face is **Canvas-rendered to a bitmap** by `WidgetBitmapRenderer.kt` so it
  honours the user's background / theme / density and matches the Flutter
  `WidgetPreview` pixel-for-pixel. It draws up to three lines — today's count,
  a "reels today" caption, and "All time · N" — sizing the block to the
  launcher-reported cell. Backgrounds `GLASS_DARK` / `GLASS_BRAND` / `SOLID` /
  `USAGE_TINT`; theme `SYSTEM` (resolved to device dark/light at draw time) /
  `LIGHT` / `DARK`; density `COZY` / `COMPACT`; optional `accentByUsage` tints the
  count via `UsageLadder`. Tapping launches the app via a `PendingIntent`.
- Dart control is `HomeWidgetRepositoryImpl`: `pin()` → the native
  `pinContentWidget` command (truthfully `false` on launchers that can't pin, so
  the editor's toast can tell the user to add it by hand), `refresh()` →
  `refreshContentWidget`. There is **no `home_widget` plugin** any more — its
  leg wrote keys native never read, rendered every pinned widget twice per push,
  and its `pin()` could not tell a launcher that can't pin from one that can.

### 5.3 Shared usage ladder — `engine/UsageLadder.kt` ↔ `usage_ladder.dart`

Both the color band (green → brown-red) and the emoji ladder step once **per 50
reels** and cap at **500** (`kUsageCap` / `CAP`). The Dart source of truth
(`content_counter_core/domain/usage_ladder.dart`) and the native mirror
(`engine/UsageLadder.kt`) must stay **byte-identical** so the bubble, widget, and
in-app previews render the same color/emoji at the same count.
`bandIndexFor(count) = count.clamp(0, 500) ~/ 50` → 0..10.

---

## 6. Dart feature (`lib/features/content_counter/**`)

Four sub-modules, registered in `lib/core/di/injector.dart`, behind one public
barrel `lib/features/content_counter/content_counter.dart` (entities, contracts,
the two cubits, `ReelCounterCard`, `BubblePreview`, `WidgetPreview`) — the only
import other features may use (`tool/check_boundaries.sh`). The bubble- and
home-widget editors are routed at `/content-counter/bubble` and
`/content-counter/widget` (`lib/core/navigation/routes.dart`); the counter's
on/off toggles and the links into those editors now live on the shared
**Appearance** screen (`/appearance`,
`lib/features/additional_feature/appearance/**`) alongside the app theme +
background, reached from the drawer and Settings. There is no longer a standalone
"Reel counter" route.

### 6.1 `content_counter_core` — live count + hub

- **Entities**: `ContentCount` (`today`, `total`, `enabled`, `bubbleEnabled`,
  `perAppToday`, `perAppTotal` — each list sorted desc — plus `timeToday`, a
  `Duration` of today's whole-app usage parsed from `timeTodayMs`, and
  `overlayGranted: bool?` — the "Display over other apps" grant, tri-state like
  the permission model: `null` = unread / unanswered, never rendered as denied;
  `bubbleBlocked` = on but grant missing) with a safe `ContentCount.empty()`
  for off-Android; `AppContentCount` (per-app tally enriched with catalog
  `appName` / `displayName` / `iconUrl`). `timeToday` is what the dashboard's
  screen-time ring reads (with the `DailyLimit` as the ring's max — see
  [07-daily-limit-scheduler.md](07-daily-limit-scheduler.md)); with `enabled`
  off the ring shows "Counting off — screen time not measured", the reels and
  streak pills show "—", and the "days under your limit" streak is **not**
  observed (usage accrual stops with the counter, so a zero there is
  unmeasured, not earned; the stored streak is reconciled again when counting
  resumes).
- **Repository**: `ContentCounterRepositoryImpl` bridges the native snapshot to
  the domain and enriches each per-app entry with catalog metadata from
  `ConfigRepository.loadBlockTargets()` (built once, cached; a catalog failure
  is logged and degrades to bare package names — it must never take the
  counter with it). `watch()` yields an initial pull then streams
  `contentCounted` events.
- **Cubit**: `ContentCounterCubit(repo, bubble)` is the one source of truth for
  every counter control surface. It streams the live `ContentCount` into the UI
  (the subscription has an `onError` — one bad read must not kill the hero
  count, breakdown and ring for the session), owns both switches
  (`setEnabled`, `setBubbleEnabled` — optimistic emit, then native; switching
  the bubble on without the grant opens the system screen), `requestOverlay()`,
  and `refresh()` — which re-pulls the snapshot so `timeToday` is fresh on
  demand **and re-reads the overlay grant** (usage time advances between
  counted reels, which the `contentCounted` stream doesn't emit; the dashboard
  hero calls it on mount and on pull-to-refresh, and `AppResumeSync` calls it on
  **every app resume** — the day-rollover repair for a dashboard kept in
  recents across midnight, and what clears a "needs permission" state after the
  user returns from Settings). Provided once, globally, in `lib/main.dart`
  (the Activity screen no longer creates a second instance).
- **UI**: `ReelCounterCard` (hero count-up card with today / all-time toggle and
  an animated per-app breakdown; reduce-motion safe) — shown on the **Activity**
  screen (`analytics_screen.dart`). Per-app icons render via the shared
  `AppIconAvatar` (bundled `social_icon_pack` asset, with a letter-tile fallback)
  — the same widget the blocklist uses. The old `ContentCounterScreen` hub was
  removed: its counting controls and the Bubble-style / Home-widget entries
  migrated to the shared **Appearance** screen
  (`features/additional_feature/appearance/presentation/appearance_screen.dart`).
  There a single **Count short videos** master switch gates the section, and the
  **Bubble** and **Home widget** are hero cards each rendering a large live
  `BubblePreview` / `WidgetPreview` you tap to open its editor. The bubble carries
  its own on/off (`bubbleEnabled`) on its card; the widget has **no** independent
  enable (a placed widget always updates), so its card is gated by the counting
  master. The section is a plain reader of the two app-wide cubits
  (`ContentCounterCubit` for switches / grant / figures,
  `CounterAppearanceCubit` for the live styles) — no `sl<>` repos and no
  `setState` mirrors of native state. When the bubble is on but the grant is
  missing (`bubbleBlocked`) the card shows a warning row — *Needs "Display over
  other apps" — tap to allow* — that opens the system screen (EVO-022). Each
  preview is an `AppPressable` (announced as a button, disabled when the surface
  is off). With counting off the Activity card's breakdown says so instead of
  promising reels that can't be counted.
- **Appearance carrier**: `CounterAppearance` (bubble + widget styles) with
  `CounterAppearanceCubit` — each setter emits immediately (so the preview tracks
  the slider with no lag) but **debounces the native push by 120ms** so dragging a
  slider doesn't flood the command channel. Provided once, app-wide, in
  `lib/main.dart` (lazy — hydrated from native by the first screen that reads
  it), so the Appearance hub and both editors share one state and an edit is
  visible on return with no re-pull; per-surface dirty flags stop the hydrate
  from overwriting an edit that beat it. The Appearance hub's third card — the
  **block screen**, with its own on/off switch — follows the same shape through
  `BlockScreenStyleCubit` ([25](25-block-screen.md) §6). `CounterAppearanceRepositoryImpl`
  hydrates from the snapshot's `bubbleStyle` / `widgetStyle` JSON (a malformed
  one is logged, then defaults) and pushes via `setCounterStyle`.
- **Wire enums**: `counter_style_enums.dart` — `BubbleVariant`,
  `WidgetBackground`, `WidgetTheme`, `WidgetDensity`, each carrying its wire token
  (`GLASS_ORB`, `GLASS_DARK`, `SYSTEM`, `COZY`, …) with an order-independent
  `fromWire` fallback.

### 6.2 `content_counter_bubble` — bubble control + style

- `BubbleStyle` entity (`variant`, `size` 40–72dp, `textScale` 0.8–1.4,
  `spacing`, `opacity` 0.5–1, `showLabel`, and `showTime` — default `true`,
  gating the tap-to-reveal-time gesture of §5.1), with `toWire` / `fromWire`
  re-clamping (the native `BubbleStyleSpec` re-clamps again — and defaults
  `showTime` to `true` — so a malformed payload can never produce an unusable
  bubble). `showTime` rides the existing `setCounterStyle` → `bubbleStyleJson`
  pipe; no new channel method.
- `BubbleRepositoryImpl` gates the bubble on/off (`setContentBubbleEnabled`) and
  reuses the existing overlay-permission channel methods (`canDrawOverlays` —
  read tri-state via `invokeBoolOrNull`, so an unanswered read is `null`, not
  "denied" — / `requestOverlayPermission`) — no new permission plumbing. The
  bubble's actual show/hide is native (driven by the foreground app); this only
  toggles the flag.

### 6.3 `home_content_counter` — widget control + style

- `WidgetStyle` entity (`background`, `theme`, `density`, `showToday`,
  `showLabel`, `showTotal`, `accentByUsage`). `fromWire` coerces an all-lines-off
  payload back to showing today's count so the widget is never blank (mirrored by
  `WidgetStyleSpec` natively).
- `HomeWidgetRepositoryImpl` — `pin()` / `refresh()` straight over the command
  channel (`pinContentWidget` / `refreshContentWidget`); the channel itself
  no-ops off-Android. The splash calls `refresh()` on launch.

### 6.4 `content_counter_appearance` — editor screens

- `BubbleStyleScreen` — variant carousel + live preview + size/text/spacing/
  opacity sliders + a "Show caption" toggle and a **"Show time on tap"**
  `AppToggleTile` (drives `showTime`); when that toggle is on, an **"On
  single tap"** demo card renders the tap-reveal at the real today-watch-time
  via `BubblePreview(time: …)` (the preview mirror gained a `time` param +
  `formatBubbleClock`, matching native `formatMs`). A "Preview count" slider
  (0–500) scrubs the usage range so the color/emoji variants read even before
  anything is watched. Every slider's value is formatted once for both the
  visible label and the screen reader (`AdaptiveSlider.semanticFormatter`), so
  TalkBack says "56 dp", not a bare percentage.
- `HomeWidgetScreen` — background carousel, theme/density `GlassSegmented`
  controls (explicit `_themes` / `_densities` order lists, not enum index
  order), line toggles, `accentByUsage`, and an "Add to home screen" button
  (`pin` → `refresh`; the confirm / launcher-unsupported fallback message is a
  `GlassToast`, not a raw `SnackBar`).
- Both read the app-wide `CounterAppearanceCubit` and seed their preview
  figures from the live `ContentCounterCubit` (no snapshot re-pull); the pinned
  Flutter previews (`BubblePreview`, `WidgetPreview` — each carries a
  `Semantics` label describing what it shows — and the design system's
  `VariantCarousel`) mirror the native render, and — because the cubit's
  debounced push live re-renders native — any on-screen bubble and pinned
  widget update as the user edits.

---

## 7. Lifecycle & independence notes

- **Enabled by default.** `cc_enabled` and `cc_bubble_enabled` both default to
  `true`; the counter runs from first launch of the service, no opt-in required.
- **Decoupled from blocking.** The counting pass runs before the `masterEnabled`
  and `pauseUntil` gates, so reels are tallied even while blocking is off, paused,
  or the specific platform is disabled for blocking. The counter never consults
  the active `BlockingPlan` (`blockAll` / `curious` (= "Conscious") / `oneReel` /
  `paused`) and never triggers a back-press. The One Reel / Unblock "reels left"
  bubble state (§5.1) is the one place the plan touches this feature, and it
  touches only the **display**: `setReelSessionRemaining` swaps what the bubble
  *shows* while a reel session runs, but the tally itself — what `count(pkg)`
  records and pushes to store/widget/event — stays blocking-independent.
- **Survives UI death.** All state is in `detoxo_engine_prefs`; the bubble and
  widget render from the native store, so they stay live and correct with the
  Flutter engine detached. Snapshot pulls prefer the live service but fall back to
  the store.
- **Disposal.** `contentCounter.dispose()` (from the service's
  `onUnbind`/`onDestroy`) removes timers and hides the bubble.
- **iOS / off-Android.** `EngineChannel` no-ops (pins return `false`, refreshes
  and the overlay read return nothing — `overlayGranted` stays `null`), and
  snapshots resolve to `ContentCount.empty()` — the feature is Android-only.

---

## Source files

Native (Android, `android/app/src/main/kotlin/com/errorxperts/detoxo/…`):

- `engine/ReelTracker.kt` — the counting decision: session + settled-page
  identity + dwell state machine (pure Kotlin, no Android imports); shares
  `settledPage()` with the One Reel gate. Tested by
  `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/ReelTrackerTest.kt`.
- `engine/ContentCounter.kt` — drives the tracker (one Handler timer), bubble
  visibility, fan-out to store/bubble/widget/event; `setReelSessionRemaining`
  passthrough for the bubble's "reels left" display (gated on the counter toggle).
- `engine/ContentCounterStore.kt` — SharedPreferences (`detoxo_engine_prefs`)
  persistence, day rollover, snapshot; `recordCount` folds the usage flush and
  returns the snapshot; `enabled` / `bubbleEnabled` cached per instance.
- `engine/DateKeys.kt` — the shared `dd-MM-yyyy` day key, memoised per minute.
- `engine/DetectionConfig.kt` — `DetectorRule.qualifiedIds` (precomputed
  target ids for `matches()`).
- `receivers/WatchdogJobService.kt` — the 15-min job also pushes the widget
  (midnight rollover repair).
- `engine/UsageLadder.kt` — shared color-band + emoji ladders (native mirror).
- `overlay/ContentCounterBubble.kt` — floating overlay + four `BubbleView`
  variants + drag/edge-snap; `setRemaining`/`lastRemaining` + the teal "reels
  left" unlock badge that overrides every variant during a reel session.
- `widget/ContentCounterWidgetProvider.kt` — `AppWidgetProvider`, push/pin.
- `widget/WidgetBitmapRenderer.kt` — Canvas bitmap render + `WidgetStyleSpec`;
  its `Palette` / `paletteFor` / `blend` / `withAlpha` / `isSystemDark` are
  `internal` and shared with the block screen ([25](25-block-screen.md)).
- `lib/features/content_counter/content_counter_appearance/presentation/widgets/widget_palette.dart`
  — `widgetPaletteFor`, the Flutter mirror of that palette, used by
  `WidgetPreview` and the block-screen preview; exported from the barrel.
- `engine/ContentCounter.kt` — `todayCount()` is also read by the block screen
  for its "N reels today" line (−1 when counting is off, so a stale number is
  never shown).
- `accessibility/DetoxoAccessibilityService.kt` — `countContent()` pass
  (`COUNT_THROTTLE_MS`, scroll-field forwarding + calibration log, the
  `countMisses` / `DFS_SKIP` stage-3 back-off), `matches(..., deep)`,
  `isReelPlatform`, `NON_REEL_PLATFORM_IDS`, `isImePackage`, foreground
  forwarding, and `syncReelBubble()` (drives the bubble's "reels left" display on
  arm/allow/revert).
- `channels/CommandHandler.kt` — `contentCounterSnapshot`,
  `setContentCounterEnabled`, `setContentBubbleEnabled`, `refreshContentWidget`,
  `setCounterStyle`, `pinContentWidget`.
- `res/xml/content_counter_widget_info.xml` — 2×2 widget metadata.
- `res/layout/content_counter_widget.xml`, `res/layout/content_counter_widget_preview.xml`
  — the `RemoteViews` host (`cc_widget_root` / `cc_widget_image`).

Dart (`lib/…`):

- `core/constants/channel_constants.dart`, `core/platform_channels/engine_channel.dart`
  — command/event names + counter channel wrappers.
- `core/di/injector.dart`, `core/navigation/routes.dart`,
  `core/navigation/app_router.dart` — DI + routes; `main.dart` provides the
  two cubits app-wide.
- `core/design_system/components/variant_carousel.dart` — the style-variant
  picker (promoted from the feature; also the shape of the Appearance
  background picker).
- `features/content_counter/content_counter.dart` — the public barrel.
- `features/content_counter/content_counter_core/domain/entities/content_count.dart`
- `features/content_counter/content_counter_core/domain/entities/app_content_count.dart`
- `features/content_counter/content_counter_core/domain/entities/counter_appearance.dart`
- `features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart`
- `features/content_counter/content_counter_core/domain/usage_ladder.dart`
- `features/content_counter/content_counter_core/domain/repositories/content_counter_repository.dart`
- `features/content_counter/content_counter_core/domain/repositories/counter_appearance_repository.dart`
- `features/content_counter/content_counter_core/data/repositories/content_counter_repository_impl.dart`
- `features/content_counter/content_counter_core/data/repositories/counter_appearance_repository_impl.dart`
- `features/content_counter/content_counter_core/presentation/content_counter_cubit.dart`
- `features/content_counter/content_counter_core/presentation/counter_appearance_cubit.dart`
- `features/content_counter/content_counter_core/presentation/widgets/reel_counter_card.dart`
- `features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart`
- `features/content_counter/content_counter_bubble/domain/repositories/bubble_repository.dart`
- `features/content_counter/content_counter_bubble/data/repositories/bubble_repository_impl.dart`
- `features/content_counter/home_content_counter/domain/entities/widget_style.dart`
- `features/content_counter/home_content_counter/domain/repositories/home_widget_repository.dart`
- `features/content_counter/home_content_counter/data/repositories/home_widget_repository_impl.dart`
- `features/content_counter/content_counter_appearance/presentation/bubble_style_screen.dart`
- `features/content_counter/content_counter_appearance/presentation/home_widget_screen.dart`
- `features/content_counter/content_counter_appearance/presentation/widgets/bubble_preview.dart`
- `features/content_counter/content_counter_appearance/presentation/widgets/widget_preview.dart`

Tests: `test/content_counter_test.dart` (snapshot mapping, catalog fallback,
`watch()` filtering, cubit switch / grant paths, `formatBubbleClock` mirror),
`test/counter_style_test.dart`, `test/usage_ladder_test.dart`, and the native
`ReelTrackerTest` (run by `bash tool/dev.sh precommit` when a JDK 17 is present).

Cross-feature (the migrated counter hub; theme + background live here too):

- `features/additional_feature/appearance/presentation/appearance_screen.dart` — the
  shared **Appearance** screen that now hosts the **Count short videos** master switch
  and the Bubble / Home-widget hero cards (large live `BubblePreview` / `WidgetPreview`,
  tapped to edit; bubble on/off on its card, widget gated by the master), plus the app
  theme (a Light/Dark `GlassSegmented` control + Match system) and background picker.
  `GlassSegmented` (design system, `components/selection.dart`) is the shared
  liquid-glass segmented control — frosted stadium track with a depth shadow and an
  accent-lit sliding pill; also used for the Reels-seen today/all-time selector.
