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
ContentCounter.kt          decides WHEN a distinct reel is counted (dwell)
   ├─ ContentCounterStore.kt   persists to SharedPreferences "detoxo_engine_prefs"
   ├─ ContentCounterBubble.kt  floating overlay (WindowManager)
   └─ ContentCounterWidgetProvider.kt + WidgetBitmapRenderer.kt  home widget
        └─ UsageLadder.kt      shared color/emoji ladders (mirrors Dart)

MethodChannel "com.errorxperts.detoxo/commands"     (pull / toggles / style)
EventChannel  "com.errorxperts.detoxo/events"        contentCounted {...}
   ▼
Dart feature lib/features/content_counter/**
   ├─ content_counter_core        ContentCount, cubits, live card, repos
   ├─ content_counter_bubble      BubbleStyle + bubble on/off + overlay perm
   ├─ home_content_counter        WidgetStyle + pin/refresh (home_widget pkg)
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
per-package throttle (`lastCountEventByPackage`, `THROTTLE_MS = 150`) separate
from the block path's throttle, so the extra tree walk stays cheap even for apps
that are not enabled for blocking.

Foreground changes are forwarded separately from `TYPE_WINDOW_STATE_CHANGED`:

```kotlin
if (contentCounter.isEnabled) {
    contentCounter.onForegroundChanged(
        pkg,
        config.platformsFor(pkg).any { isReelPlatform(it) },
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

### 2.3 Distinct-reel heuristic (dwell + scroll)

The core decision lives in `ContentCounter.kt`. State mutates only on the
service's single main thread; all timers post to the same main `Looper`, so no
locks are needed. Signals from the service:

| Signal | Fired when | Effect |
| --- | --- | --- |
| `onForegroundChanged(pkg, isReelApp)` | window-state change to a new package | ends the current reel; hides the bubble if leaving for a non-reel app; ignores our own package + `com.android.systemui` |
| `onReelSurfaceSeen(pkg)` | a reel surface is detected on screen | refreshes `lastReelSurfaceAtMs`, shows the bubble, starts a dwell window |
| `onNoReelSurface(pkg)` | a reel app's window was checked and had **no** reel surface (e.g. the feed) | ends the reel, schedules a graced bubble hide |
| `onScroll(pkg)` | `TYPE_VIEW_SCROLLED` in a reel app | ends the current dwell (advances to the "next reel") |

A reel is **counted once** it satisfies the dwell rule:

- On the first `onReelSurfaceSeen`, `startReel()` posts `dwellRunnable` after
  `MIN_VIEW_MS = 2000ms`.
- When the timer fires (`onDwellElapsed`), the reel is counted **only if** the
  surface is still fresh — `now − lastReelSurfaceAtMs ≤ REEL_SURFACE_STALE_MS
  (2000ms)` — i.e. the user is still watching, not flicked past.
- `reelCounted` guards against double-counting the same dwell window.
- A **scroll ends the dwell** (`onScroll → endReel`); the next detected surface
  starts a fresh window. So lingering on one reel counts it once; scrolling
  through N reels (each dwelt on ≥2s) counts N.

This "watch ≥ ~2s" rule is the anti-inflation heuristic surfaced verbatim to the
user in the counter screen's hint ("A video counts only after you've watched it
for about 2 seconds — quick scrolls are ignored").

### 2.4 Bubble visibility (positive-evidence hide)

The bubble is **shown** by `onReelSurfaceSeen` and stays up the entire time the
user watches — even during a passive, event-quiet video, because a detection gap
never hides it. It is **hidden only on positive evidence** the user left reels:

- `onNoReelSurface` (a checked window with no reel surface, e.g. the feed) → a
  single graced hide after `HIDE_GRACE_MS = 1500ms` (bridges between-reel
  transitions without flicker), or
- `onForegroundChanged` to another real app → immediate hide.

Our own overlay window and system UI are ignored (`TRANSIENT_PKGS`) so the bubble
can never self-toggle into a show/hide loop.

### 2.5 Fan-out on each count

`count(pkg)` does five things:

1. `flushUsage()` — settle the batched usage window first, so the event's
   `timeTodayMs` includes the accumulated-but-unwritten time.
2. `store.recordCount(pkg, dateKey())` — persist.
3. Emit the `contentCounted` event on `ServiceEventBus` (see §4).
4. `pushWidget(snapshot)` — throttled to `WIDGET_MIN_INTERVAL_MS = 1000ms` so a
   burst of counts can't hammer the launcher.
5. If the bubble is enabled and visible, `bubble.onCounted(today)` (springy pop).

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

> `cc_today` / `cc_total` are also the two keys the Dart `home_widget` fallback
> writes (§5.2) — the same names, so the two paths agree.

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
| `setContentCounterEnabled` | `setContentCounterEnabled(enabled:)` | writes `store.enabled` **and** calls `contentCounter.setEnabled` on the live service |
| `setContentBubbleEnabled` | `setContentBubbleEnabled(enabled:)` | writes `store.bubbleEnabled` **and** `contentCounter.setBubbleEnabled` |
| `refreshContentWidget` | `refreshContentWidget()` | `ContentCounterWidgetProvider.pushUpdate(...)` from the store |
| `setCounterStyle` | `setCounterStyle(bubble:, widget:)` | persists only the present style key(s), then live re-renders the visible bubble (`onStyleChanged`) and every pinned widget |
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
  counter pushes updates).
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
- Dart control is `HomeWidgetRepositoryImpl` (using the **`home_widget`**
  package). `pin()` calls `HomeWidget.requestPinWidget`, falling back to the
  native `pinContentWidget` command if the plugin/launcher refuses.
  `pushSnapshot` writes `home_widget` keys **`cc_today` / `cc_total`** and then
  calls `refreshContentWidget` — but the native bitmap render (from the store) is
  the real source, so `home_widget` being unavailable never breaks the widget.

### 5.3 Shared usage ladder — `engine/UsageLadder.kt` ↔ `usage_ladder.dart`

Both the color band (green → brown-red) and the emoji ladder step once **per 50
reels** and cap at **500** (`kUsageCap` / `CAP`). The Dart source of truth
(`content_counter_core/domain/usage_ladder.dart`) and the native mirror
(`engine/UsageLadder.kt`) must stay **byte-identical** so the bubble, widget, and
in-app previews render the same color/emoji at the same count.
`bandIndexFor(count) = count.clamp(0, 500) ~/ 50` → 0..10.

---

## 6. Dart feature (`lib/features/content_counter/**`)

Four sub-modules, registered in `lib/core/di/injector.dart`. The bubble- and
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
  `Duration` of today's whole-app usage parsed from `timeTodayMs`) with a safe
  `ContentCount.empty()` for off-Android; `AppContentCount` (per-app tally
  enriched with catalog `appName` / `displayName` / `iconUrl`). `timeToday` is
  what the dashboard's screen-time ring reads (with the `DailyLimit` as the ring's
  max — see [07-daily-limit-scheduler.md](07-daily-limit-scheduler.md)).
- **Repository**: `ContentCounterRepositoryImpl` bridges the native snapshot to
  the domain and enriches each per-app entry with catalog metadata from
  `ConfigRepository.loadBlockTargets()` (built once, cached). `watch()` yields an
  initial pull then streams `contentCounted` events.
- **Cubit**: `ContentCounterCubit` streams the live `ContentCount` into the UI
  and exposes `setEnabled` and `refresh()` — a `refresh()` re-pulls the snapshot
  so `timeToday` is fresh on demand (usage time advances between counted reels,
  which the `contentCounted` stream doesn't emit; the dashboard hero calls it on
  mount and on pull-to-refresh, and `AppResumeSync` calls it on **every app
  resume** — the day-rollover repair for a dashboard kept in recents across
  midnight). It is provided globally in `lib/main.dart` so the
  dashboard ring can watch it.
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
  master. The screen reads/writes the same `ContentCounterRepository` /
  `BubbleRepository` / `CounterAppearanceRepository`.
- **Appearance carrier**: `CounterAppearance` (bubble + widget styles) with
  `CounterAppearanceCubit` — each setter emits immediately (so the preview tracks
  the slider with no lag) but **debounces the native push by 120ms** so dragging a
  slider doesn't flood the command channel. `CounterAppearanceRepositoryImpl`
  hydrates from the snapshot's `bubbleStyle` / `widgetStyle` JSON and pushes via
  `setCounterStyle`.
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
  reuses the existing overlay-permission channel methods (`canDrawOverlays` /
  `requestOverlayPermission`) — no new permission plumbing. The bubble's actual
  show/hide is native (driven by the foreground app); this only toggles the flag.

### 6.3 `home_content_counter` — widget control + style

- `WidgetStyle` entity (`background`, `theme`, `density`, `showToday`,
  `showLabel`, `showTotal`, `accentByUsage`). `fromWire` coerces an all-lines-off
  payload back to showing today's count so the widget is never blank (mirrored by
  `WidgetStyleSpec` natively).
- `HomeWidgetRepositoryImpl` (`home_widget` package) — `pin` / `pushSnapshot`
  (writes `cc_today` / `cc_total`) / `refresh`; guarded by
  `PlatformCapabilities.supportsBlockingEngine` and try/caught so the plugin
  failing never breaks counting.

### 6.4 `content_counter_appearance` — editor screens

- `BubbleStyleScreen` — variant carousel + live preview + size/text/spacing/
  opacity sliders + a "Show caption" toggle and a **"Show time on tap"**
  `AppToggleTile` (drives `showTime`); when that toggle is on, an **"On
  single tap"** demo card renders the tap-reveal at the real today-watch-time
  via `BubblePreview(time: …)` (the preview mirror gained a `time` param +
  `formatBubbleClock`, matching native `formatMs`). A "Preview count" slider
  (0–500) scrubs the usage range so the color/emoji variants read even before
  anything is watched.
- `HomeWidgetScreen` — background carousel, theme/density segmented controls,
  line toggles, `accentByUsage`, and an "Add to home screen" button
  (`pin` → `refresh`; the confirm / launcher-unsupported fallback message is a
  `GlassToast`, not a raw `SnackBar`).
- Both drive `CounterAppearanceCubit`; the pinned Flutter previews
  (`BubblePreview`, `WidgetPreview`, `VariantCarousel`) mirror the native render,
  and — because the cubit's debounced push live re-renders native — any on-screen
  bubble and pinned widget update as the user edits.

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
- **iOS / off-Android.** `EngineChannel` no-ops, snapshots resolve to
  `ContentCount.empty()`, and `HomeWidgetRepositoryImpl` short-circuits on
  `PlatformCapabilities.supportsBlockingEngine` — the feature is Android-only.

---

## Source files

Native (Android, `android/app/src/main/kotlin/com/errorxperts/detoxo/…`):

- `engine/ContentCounter.kt` — counting brain: dwell/scroll heuristic, bubble
  visibility, fan-out to store/bubble/widget/event; `setReelSessionRemaining`
  passthrough for the bubble's "reels left" display (gated on the counter toggle).
- `engine/ContentCounterStore.kt` — SharedPreferences (`detoxo_engine_prefs`)
  persistence, day rollover, snapshot.
- `engine/UsageLadder.kt` — shared color-band + emoji ladders (native mirror).
- `overlay/ContentCounterBubble.kt` — floating overlay + four `BubbleView`
  variants + drag/edge-snap; `setRemaining`/`lastRemaining` + the teal "reels
  left" unlock badge that overrides every variant during a reel session.
- `widget/ContentCounterWidgetProvider.kt` — `AppWidgetProvider`, push/pin.
- `widget/WidgetBitmapRenderer.kt` — Canvas bitmap render + `WidgetStyleSpec`.
- `accessibility/DetoxoAccessibilityService.kt` — `countContent()` pass,
  `isReelPlatform`, `NON_REEL_PLATFORM_IDS`, foreground/scroll forwarding, and
  `syncReelBubble()` (drives the bubble's "reels left" display on arm/allow/revert).
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
  `core/navigation/app_router.dart` — DI + routes.
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
- `features/content_counter/content_counter_appearance/presentation/widgets/variant_carousel.dart`

Cross-feature (the migrated counter hub; theme + background live here too):

- `features/additional_feature/appearance/presentation/appearance_screen.dart` — the
  shared **Appearance** screen that now hosts the **Count short videos** master switch
  and the Bubble / Home-widget hero cards (large live `BubblePreview` / `WidgetPreview`,
  tapped to edit; bubble on/off on its card, widget gated by the master), plus the app
  theme (a Light/Dark `GlassSegmented` control + Match system) and background picker.
  `GlassSegmented` (design system, `components/selection.dart`) is the shared
  liquid-glass segmented control — frosted stadium track with a depth shadow and an
  accent-lit sliding pill; also used for the Reels-seen today/all-time selector.
