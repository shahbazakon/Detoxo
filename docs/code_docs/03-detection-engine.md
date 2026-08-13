# Detection & Block Engine

The native heart of Detoxo. A single Android `AccessibilityService`
(`DetoxoAccessibilityService`) receives every accessibility event on the device,
decides whether the foreground surface is a short-form-video reel/short, and — if
the active plan says so — dismisses it (Press Back / Kill / Lock). It also drives
the decoupled content counter and web blocking, and runs a 1 Hz "Conscious"
accountant. Everything below is authored from the real Kotlin source; the Flutter
side only pushes config/settings and mirrors the timing constants for UI use.

- Service class: `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- Config model: `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DetectionConfig.kt`
- Settings/config store: `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt`
- Dart timing mirror: `lib/core/constants/app_constants.dart` (`EngineTimings`)

The service runs in the **main process** (there is no separate `:as_process`) and
is itself the foreground service — see [04-native-android-layer.md](04-native-android-layer.md).

---

## 1. Lifecycle & wiring

| Hook | Behaviour |
|------|-----------|
| `onServiceConnected()` | Sets the `instance` singleton, constructs `ConfigStore`, calls `reload()`, calls `showStatusNotification()`, posts `serviceStatus {running:true}`. |
| `reload()` | Re-parses `DetectionConfig.parse(store.platformsConfigJson)`, refreshes the web blocklist + adult flag, calls `syncConscious()` **and `syncReelBubble()`** (pushes the One Reel / Unblock "reels left" count to the counter bubble — §5.3). Invoked whenever Dart pushes new config/settings. |
| `onInterrupt()` | Posts `serviceStatus {running:false}`. |
| `onUnbind()` / `onDestroy()` | Clears `instance`, stops the Conscious accountant, disposes the content counter, posts `serviceStatus {running:false}`. |
| `onTaskRemoved()` | Re-posts the status notification if swiping the app away cleared it. The service itself is bound by the system, so it survives regardless. |

`instance` is a `@Volatile` companion singleton; `isRunning()` returns
`instance != null`. The `CommandHandler` reaches the live service (e.g. for
`performBack`, `consciousState`, content-counter toggles) through this singleton.

Config is held as a `@Volatile var config: DetectionConfig` so the hot event path
reads a consistent snapshot while Dart can swap it via `reload()`.

Status notification: channel id `detoxo_protection_channel`, name
`"Detoxo Service Status"`, `IMPORTANCE_LOW`, `NOTIF_ID = 1125`, posted with
`NotificationManager.notify()`. The service is **not** a foreground service —
see [04-native-android-layer.md](04-native-android-layer.md) §2.

---

## 2. `onAccessibilityEvent` — the hot loop

Every event flows through one ordered gauntlet of guards. Order matters: the
counting pass is deliberately placed **before** any block/gate logic so counting
never depends on blocking being active.

```
onAccessibilityEvent(event):
  pkg = event.packageName            ; return if null
  pkgProtected = isProtected(pkg)    ; privacy-protected app? (cached set)
  if WINDOW_STATE_CHANGED:           ; track foreground for Conscious + counter
      foregroundPkg = pkg
      if pkgProtected or no platforms for pkg: lastReelAtMs = 0  ; end "watching"
      contentCounter.onForegroundChanged(pkg, !pkgProtected && isReelBearing)
  if pkgProtected or isProtected(foregroundPkg): return  ; PRIVACY GUARD (see 24)
  if pkg == our own package: return
  if contentCounter.isEnabled: countContent(event, pkg)   ; side-effect-free
  if !store.masterEnabled: return                          ; master kill-switch
  if now < store.pauseUntil: return                        ; Pause window
  if plan==ONE_REEL and event==VIEW_SCROLLED and pkg has platforms:
      lastScrollAtMs = now                                 ; capture reel advance BEFORE throttle
  ── per-package throttle (THROTTLE_MS = 150) ──
  if BrowserUrlExtractor.isBrowser(pkg):                   ; web blocking branch
      handleBrowser(pkg) on window/content change; return
  platforms = config.platformsFor(pkg)   ; return if empty
  for each platform (LEGACY/OVERLAY, enabled):
      for each detector (FINDBYID / VIEWID_RES_NAME):
          if matches(root, event, detector, pkg):
              if plan==CURIOUS and bank>0: lastReelAtMs=now; return   ; let it play
              if plan==ONE_REEL and allowReelOrBlock(now): return     ; within allowance
              onDetected(pkg, platformId, detector)
              if detector.haltOnDetect: return
```

### 2.1 Guard order (verbatim from source)

1. **Null package** → return.
2. **Foreground tracking** (on `TYPE_WINDOW_STATE_CHANGED` only): set
   `foregroundPkg`; if the new app is privacy-protected **or** has *no*
   configured platforms, reset `lastReelAtMs = 0` (immediately ends "watching"
   so the Conscious bank can start earning — and so a stale watching window can
   never survive a switch into a protected app); notify the content counter of
   the foreground change with a flag for whether the app carries reel surfaces
   (forced `false` for a protected app, which hides the bubble).
3. **Privacy guard** — `if (pkgProtected || isProtected(foregroundPkg)) return`.
   The single protected-apps decision point: while a protected app (banking,
   UPI, password manager…) is the event source *or* the focused window, nothing
   below runs — no counting, no browser URL reads, no tree walks, no blocking.
   The dual check keeps split-screen safe (`rootInActiveWindow` is the
   *focused* pane, so an event from the other pane must never walk it).
   Full design in [24-protected-apps.md](24-protected-apps.md).
4. **Self-package** (`pkg == packageName`) → return (never act on Detoxo's own UI).
5. **Content counting** — `if (contentCounter.isEnabled) countContent(event, pkg)`.
   Runs even when blocking is off/paused/disabled (see §6).
6. **Master switch** — `if (!store.masterEnabled) return`. Default `true`.
7. **Pause gate** — `if (System.currentTimeMillis() < store.pauseUntil) return`.
   Clock-based; suspends *all* blocking regardless of the pushed plan name (see §5).
8. **Per-package throttle** — see §3. Immediately *before* this throttle, under the
   `ONE_REEL` plan a `TYPE_VIEW_SCROLLED` from a monitored app stamps
   `lastScrollAtMs` — a throttled scroll would hide a reel advance and leak the next
   reel past the allowance (see §5.3).
9. **Browser branch** — if the package is a known browser, run web blocking
   (only on `WINDOW_STATE_CHANGED` / `WINDOW_CONTENT_CHANGED`, and only if the
   blocklist has rules) and `return`. Browsers carry no reel surfaces, so the
   reel path is skipped either way. Detailed in
   [06-app-and-web-blocker.md](06-app-and-web-blocker.md).
10. **Reel detection** — iterate the package's platforms/detectors (§4), apply the
    Conscious allowance check (§5.2) **or the One Reel / Unblock gate (§5.3)**, then
    execute the block (§4.4).

---

## 3. Per-package throttle (`THROTTLE_MS = 150`)

Reel apps fire content-changed events in storms. To keep the (potentially
tree-walking) detection cheap, each package is throttled to at most one detection
pass per 150 ms:

```kotlin
val now = System.currentTimeMillis()
val last = lastEventByPackage[pkg] ?: 0L
if (now - last < THROTTLE_MS) return
lastEventByPackage[pkg] = now
```

`lastEventByPackage` is a `ConcurrentHashMap<String, Long>`. The counting pass
keeps its **own** independent throttle map (`lastCountEventByPackage`, same
150 ms) so counting and blocking never starve each other.

---

## 4. The 3-stage view-id detection (`matches`)

`matches(root, event, detector, pkg)` is the verified detection primitive shared
by both the block path and the counting path. A detector carries a list of
`identifiers` (resource-id fragments). Two detector kinds are honoured:

- **`FINDBYID`** — the id is package-qualified: the target is `"$pkg$id"`
  (e.g. `com.instagram.androidid/clips_video_container`).
- **`VIEWID_RES_NAME`** — the id is used **verbatim** as the target.

`byResName = detector.viewDetector == "VIEWID_RES_NAME"` selects which form to
build for `target`. Every positive match is gated on `isVisibleToUser` so an
off-screen/recycled node never triggers a block.

The three stages run cheapest-first and short-circuit on the first visible hit:

| Stage | Source | Cost | Logic |
|-------|--------|------|-------|
| 1 | `event.source` | O(ids) | Compare `source.viewIdResourceName` to each `target`; require `source.isVisibleToUser`. |
| 2 | `root.findAccessibilityNodeInfosByViewId(target)` | O(ids), native index | For each id, look up nodes by view-id; return on the first visible hit. |
| 3 | Bounded DFS over the tree | O(min(nodes, 12000)) | Walk from `root`; compare each node's `viewIdResourceName`; return on first visible hit. |

### 4.1 Stage 3 DFS cap (`MAX_NODES = 12000`)

The DFS uses an explicit `ArrayDeque<AccessibilityNodeInfo>` (LIFO —
`addLast`/`removeLast`), not recursion, to bound stack use and allow a hard node
cap:

```kotlin
val deque = ArrayDeque<AccessibilityNodeInfo>()
deque.addLast(root)
var i = 0
while (deque.isNotEmpty() && i < MAX_NODES) {
    val node = deque.removeLast()
    i++
    val resName = node.viewIdResourceName
    if (resName != null) {
        for (id in detector.identifiers) {
            val target = if (byResName) id else "$pkg$id"
            if (resName == target && node.isVisibleToUser) return true
        }
    }
    for (c in node.childCount - 1 downTo 0) {
        node.getChild(c)?.let { deque.addLast(it) }
    }
}
return false
```

Children are pushed in reverse (`childCount-1 downTo 0`) so that popping from the
tail visits them left-to-right. The counter `i` caps the walk at 12000 nodes,
bounding worst-case latency on pathological trees. (`DetectorRule.childNodeLimit`
is parsed from config but is **not** currently consulted in `matches` — the fixed
`MAX_NODES` governs.)

### 4.2 Platform / detector selection

For the reel path, only platforms whose `detectionType` is `LEGACY` or `OVERLAY`
are acted on (`CALIBRATION`/`MANUAL`/`NONE` are skipped). Enable/disable is
resolved against `store.enabledPlatforms`:

```kotlin
val isOn = if (enabled.isEmpty()) platform.defaultStatus
          else enabled.contains(platform.platformId)
if (!isOn) continue
```

i.e. if the user has never set an enabled set, each platform falls back to its
config `defaultStatus`; otherwise membership in the set decides. Within a
platform, only `FINDBYID` / `VIEWID_RES_NAME` detectors run; `CONT_DESC` /
`BROWSER` detector kinds are skipped on this path. Detectors are pre-sorted by
`priority` ascending at parse time (§7).

### 4.3 `haltOnDetect`

After a successful `onDetected`, if `detector.haltOnDetect` is true the loop
returns immediately (one block per event). Defaults to `true` in config parsing.

### 4.4 Block execution — `onDetected`

```kotlin
private fun onDetected(pkg, platformId, detector) {
    val now = System.currentTimeMillis()
    if (now - lastBlockTime <= BLOCK_DEBOUNCE_MS) return   // 1200 ms debounce
    lastBlockTime = now
    val mode = resolveBlockMode(detector)
    store.recordBlock(dateKey())                            // dd-MM-yyyy counter
    ServiceEventBus.post("blocked", {package, platformId, mode, today, total})
    when (mode) {
        "KILL_APP"    -> { blockVibrate(); performBackInternal(); killApp(pkg) }
        "LOCK_SCREEN" -> { blockVibrate(); performBackInternal(); lockScreen() }
        "NONE"        -> { /* no-op */ }
        else          -> pressBackWithRateLimit()           // PRESS_BACK default
    }
}
```

**Block modes**

| Mode | Action | Notes |
|------|--------|-------|
| `PRESS_BACK` (default) | `performGlobalAction(GLOBAL_ACTION_BACK)` via `pressBackWithRateLimit()` | Rate-limited (§4.5). |
| `KILL_APP` | Back, then `ActivityManager.killBackgroundProcesses(pkg)` | Best-effort; catches throwables. |
| `LOCK_SCREEN` | Back, then device-admin `DevicePolicyManager.lockNow()` | Only if admin active (`admin/DetoxoDeviceAdminReceiver`). |
| `NONE` | No-op | `onDetected` runs `recordBlock`/emit *before* the `when`, so a `NONE` detector still records the stat and emits a `blocked` event but performs no navigation. |

**`resolveBlockMode(detector)`** picks the mode:

1. Take the user's `store.defaultBlockMode`. If it isn't `NONE` **and** the
   detector either lists no `supportedBlockModes` or explicitly supports it → use it.
2. Otherwise use the detector's first supported non-`NONE` mode.
3. Otherwise fall back to the detector's `defaultBlockMode`, defaulting to
   `PRESS_BACK` when blank.

### 4.5 Debounce vs. back rate-limit (two separate clocks)

Two independent guards, easy to confuse:

| Constant | Value | Guards | Field |
|----------|-------|--------|-------|
| `BLOCK_DEBOUNCE_MS` | **1200 ms** | Whole `onDetected` — at most one block action per 1.2 s across all modes. | `lastBlockTime` |
| `BACK_RATE_LIMIT_MS` | **1100 ms** | Only simulated Back presses (`pressBackWithRateLimit`). | `lastBackTime` |

```kotlin
private fun pressBackWithRateLimit() {
    val now = System.currentTimeMillis()
    if (now - lastBackTime <= BACK_RATE_LIMIT_MS) return
    lastBackTime = now
    performBackInternal()   // performGlobalAction(GLOBAL_ACTION_BACK)
    blockVibrate()
}
```

The back rate-limit is also shared by the **web-blocking** path and by the
Conscious "bank drained" boot, so a reel bounce and a web-block bounce can't
double-fire back presses inside 1.1 s. `blockVibrate()` fires a 60 ms one-shot
(`BLOCK_VIBRATION_MS`, amplitude 255) only when `store.vibrationEnabled`.

`performBackInternal()` is exposed publicly as `performBackPublic()` for the
`performBack` command; `killApp`/`lockScreen` are also public for their commands.

---

## 5. Conscious plan & Pause gating

The active plan lives in `store.activePlan` (default `"BLOCK_ALL"`). Detoxo's
plan enum is `{ blockAll, curious, oneReel, paused }`. **`curious` / wire token
`CURIOUS` is the internal name; the user-facing label is "Conscious".** The
native constant is `PLAN_CONSCIOUS = "CURIOUS"`.

### 5.1 Pause — clock-based window

Pause is **not** an `activePlan` branch in the hot loop; it is a pure clock gate:

```kotlin
if (System.currentTimeMillis() < store.pauseUntil) return
```

`pauseUntil` is epoch-millis (0 = not paused). While the window is open, *every*
app is allowed and no blocking runs; when the clock passes `pauseUntil`, the
underlying active plan resumes automatically. This is intentionally decoupled
from the plan name so it works regardless of which plan is set.

### 5.2 Conscious — earn-as-you-abstain token bank

Conscious lets reels play *while the user has banked allowance*, then boots them
when the bank empties. State lives in `ConfigStore`:

| Field | Default | Meaning |
|-------|---------|---------|
| `consciousBankMs` | 0 | Currently banked allowance (0..max), millis. |
| `consciousMaxBankMs` | 600 000 (10 min) | Bank ceiling. |
| `consciousEarnDivisor` | 10 (≥1) | Refill rate: `bank += elapsed / divisor` while abstaining. |
| `consciousAnchorMs` | — | Wall-clock anchor of the last accounting tick. |

**In the detection loop**, when a reel matches under Conscious:

```kotlin
if (store.activePlan == PLAN_CONSCIOUS && store.consciousBankMs > 0L) {
    lastReelAtMs = now   // mark "watching" so the accountant drains the bank
    return               // let the reel play — do NOT block
}
onDetected(...)          // empty bank → fall through and block as normal
```

So a detected reel with a positive bank plays (and marks `lastReelAtMs`); with an
empty bank it is blocked like any other plan, which counts as abstaining and lets
the bank start refilling.

**The 1 Hz accountant** (`CONSCIOUS_TICK_MS = 1000`) runs on the main-looper
`Handler` whenever the plan is Conscious, so the bank keeps ticking even when the
Flutter UI is dead. `syncConscious()` starts/stops it to match the plan and
anchors `consciousAnchorMs = now` on start (so service downtime isn't
retroactively credited; the persisted bank carries over).

`accountConscious()` — one step:

```
if plan != CURIOUS: return
elapsed = clamp(now - anchor, >=0); anchor = now      // advance first, always
if !masterEnabled: emit; return                        // freeze (no drain/accrue)
if now < pauseUntil: emit; return                      // freeze during a live Pause (Conscious base)
if isProtected(foregroundPkg):                         // privacy: freeze + drop stale watching
    lastReelAtMs = 0; emit; return                     // never BACK-press into a protected app
watching = (now - lastReelAtMs) < WATCH_STALE_MS (2500 ms)
inReelApp = foregroundPkg has any configured platform
if watching:
    bank -= min(elapsed, CONSCIOUS_MAX_STEP_MS=5000)   // cap a delayed tick
    if bank <= 0: bank = 0; lastReelAtMs = 0; pressBackWithRateLimit()  // boot
else if !inReelApp:
    bank = min(bank + elapsed / earnDivisor, maxBank)  // accrue only truly off-reels
// else lingering on a reel app, detection quiet → hold steady
store.consciousBankMs = max(bank, 0)
emit consciousState
```

Key nuances:
- **Drain 1:1** while watching; **accrue at `1/divisor`** only when the foreground
  app has no configured reel platforms at all.
- A **paused reel** (reel app foreground, detection gone quiet) neither drains nor
  refills — it holds steady, so pausing a video can't farm allowance.
- A **live Pause** window (`now < pauseUntil`) **freezes** the bank, mirroring the
  master-off freeze: when Conscious is the base mode being paused, every app is
  allowed and the reel gate is off, so the bank must not silently accrue free
  allowance while the user scrolls unblocked. The anchor is already advanced, so
  re-blocking after the pause can't dump a huge credit.
- `CONSCIOUS_MAX_STEP_MS = 5000` caps a single drain step so a delayed/coalesced
  tick can't dump the whole bank at once.
- `WATCH_STALE_MS = 2500`: a reel seen within 2.5 s still counts as "watching".
- A **privacy-protected foreground app** freezes the bank *and* zeroes
  `lastReelAtMs` — without this, the 2.5 s stale-watching window could survive a
  reel-app → banking-app switch and the timer would press BACK inside the bank
  when the bank hits 0. `performBackInternal` / `killApp` / `lockScreen` carry
  the same guard as a fail-closed backstop (see
  [24-protected-apps.md](24-protected-apps.md)).

**`consciousState` event / `consciousSnapshot`** carries
`{bankMs, maxBankMs, watching, blocked, active}` where
`watching = active && (now-lastReelAtMs) < 2500`, `blocked = active && bank <= 0`.
`emitConsciousState` is fired on every tick and on `syncConscious`. The snapshot
also backs the `consciousState` pull command.

### 5.3 One Reel / Unblock — allow N reels, then block

`oneReel` (wire `ONE_REEL`, native `PLAN_ONE_REEL = "ONE_REEL"`) is the third
`activePlan` the hot loop enforces. It grants a fixed `store.reelAllowance` (1..20;
`= 1` is "One Reel", `2..20` is "Unblock N") and blocks once the allowance is spent.
State in `ConfigStore`: `reelAllowance` (key `reel_allowance`) and the **persisted**
`reelsConsumed` (key `reels_consumed`). No 1 Hz accountant — enforcement is purely
event-driven inside the detector loop.

**A reel counts only after 2s of dwell.** A reel is added to `reelsConsumed` **only
after it's been watched for `MIN_VIEW_MS = 2000 ms`** (matching the awareness
counter's dwell), so a quick flick-through (<2s) doesn't count, and a **single
looping reel costs at most one count** — a `reelViewCounted` latch prevents
re-counting the same view. Reels are still **scroll-delimited** (consecutive reels
share the same continuously-visible view-id, so `matches()` fires the whole time a
reel is up), but a scroll only counts as an **advance to a new reel** once **≥ 2s
have passed since the last count** (`lastReelCountMs`) — this **debounces in-reel
scrolls** (opening comments/captions/carousels) so they don't burn the allowance or
block the reel you're still watching. The reel-advance scroll (`TYPE_VIEW_SCROLLED`
from a monitored app) is still stamped into the runtime `@Volatile lastScrollAtMs`
**before** the 150 ms throttle (§2.1 step 7); a scroll swallowed by the throttle
would hide the advance.

In the detector loop, when a reel matches under `ONE_REEL`:

```kotlin
if (store.activePlan == PLAN_ONE_REEL && allowReelOrBlock(now)) return  // allow
onDetected(...)                                                          // spent → block
```

`allowReelOrBlock(now)`:
- `advanced = reelViewStartMs == 0L || (lastScrollAtMs > reelViewStartMs && now − lastReelCountMs ≥ MIN_VIEW_MS)`
  — a fresh view is a session/app start or a real scroll-advance that's ≥ 2s past
  the last count (so an in-reel scroll isn't read as moving on).
- On an **advance**: first count the reel being *left* if it was watched ≥ 2s and not
  already counted (`countReel` — covers a passively-watched reel whose surface stopped
  emitting events before its 2s tick fired); then start the new view
  (`reelViewStartMs = now`, `reelViewCounted = false`). If `reelsConsumed ≥
  reelAllowance` this fresh reel is **blocked** (`emitReelSessionState(blocked = true)`,
  return false); otherwise allow it.
- **Same reel continuing**: the currently-playing reel is **never blocked** — it's
  counted once it crosses the 2s dwell (`!reelViewCounted && now − reelViewStartMs ≥
  MIN_VIEW_MS → countReel`), then always allowed.

`countReel(now)` does the tally: `reelsConsumed += 1`, sets the `reelViewCounted`
latch, stamps `lastReelCountMs`, emits state, and calls `syncReelBubble()`. Counting
thus happens on **either** the 2s same-reel dwell tick **or** when advancing away from
a reel watched ≥ 2s.

`reelsConsumed` is **persisted**, so an OS-driven service restart keeps the user
blocked until an explicit re-tap; `reload()` / `onServiceConnected` do **not** reset
it — only the imperative `armReelSession` (via `store.resetReelSession()`) does. The
runtime dwell fields — `reelViewStartMs`, `reelViewCounted`, `lastReelCountMs`,
`lastScrollAtMs` — are all zeroed by `armReelSession()` (which then reloads and emits
a `reelSessionState` event `{consumed, allowance, blocked, active}`, also backing the
pull query), and `reelViewStartMs` is reset whenever the user leaves the reel app so
the next reel starts as a fresh view.

**Reel-counter bubble "reels left".** The gate also drives the content-counter
bubble's display: `syncReelBubble()` pushes
`reelAllowance − reelsConsumed` (coerced ≥ 0, or `null` when the plan isn't
`ONE_REEL`) to `ContentCounter.setReelSessionRemaining`. It runs at the end of
`reload()` (covers arm and revert-to-base) and again inside `countReel` right after
the `reelsConsumed` increment, so the bubble's countdown ticks down per watched reel
(i.e. once a reel clears its 2s dwell). This is display-only — the counter's own tally
stays blocking-independent. Full detail in [17-content-counter.md](17-content-counter.md) §5.1.

The emitted `reelSessionState` with **`blocked = true`** is also the sole trigger for
the Dart-side **auto-revert**: `SettingsCubit` listens on `reelSessionStream()` and,
once the allowance is spent, flips the plan back to the sticky base mode (Block All /
Conscious). Native still owns the count and still boots the over-allowance reel here;
the override simply doesn't sit blocked afterwards. Full Dart/UI side in
[05-plans-pause-conscious.md](05-plans-pause-conscious.md) §7.4.

> `ponytail:` reel identity is heuristic (scroll + 2s dwell, no per-reel id). A
> spurious scroll **> 2s** after a count can still be misread as an advance, and a
> fast scroll **within 2s** of a count is absorbed into the current reel (a small
> leniency — safer than false-blocking the reel you're still watching). Accepted
> ceiling; the service comment names the upgrade path (content-based reel identity).
> Full Dart/UI side in [05-plans-pause-conscious.md](05-plans-pause-conscious.md) §7.

---

## 6. Content counting is decoupled from blocking

`countContent(event, pkg)` runs before the master/pause gates and is strictly
**side-effect-free** with respect to blocking: it never presses back and never
reads/writes block state. It:

1. Accrues **whole-app usage time** for monitored apps via
   `contentCounter.onAppActivity(pkg)` (see below), before the throttle.
2. On `TYPE_VIEW_SCROLLED`, forwards `contentCounter.onScroll(pkg)` (cheap proxy
   for "advanced to next reel"; the counter debounces internally).
3. Applies its **own** 150 ms per-package throttle (`lastCountEventByPackage`).
4. Reuses the read-only `matches()` walk against **reel** platforms only
   (`isReelPlatform`, which excludes `NON_REEL_PLATFORM_IDS`: `ig_feed`,
   `ig_stories`, `insta_pro_stories`, `insta_pro2_stories`, `snap_stories`,
   `wa_status`, `wab_status`). A hit → `onReelSurfaceSeen(pkg)`; actively
   checking a reel app and finding no reel surface → `onNoReelSurface(pkg)`
   (distinct from "no event", which never reaches here).

**Usage-time accrual (`onAppActivity`) — no new permission.** For every event
from a package that has *any* configured platform (feed / stories / DMs / reels —
broader than the reel-surface set), `countContent` calls `onAppActivity(pkg)`,
which sums the gap between consecutive events from the **same** monitored app but
only when that gap is under `USAGE_ACTIVE_GAP_MS = 12000ms`. A longer silence
(screen off / user away → no events) starts a fresh window and isn't counted, so
this measures active foreground time and (a documented `ponytail:` ceiling)
undercounts truly passive, event-quiet playback. Each delta is persisted via
`ContentCounterStore.recordUsage` into `cc_time_today` / `cc_time_total`. This
reuses the existing AccessibilityService — **no extra Android permission** — and
feeds the dashboard's screen-time ring and the bubble's tap-to-reveal-time. Full
detail in [17-content-counter.md](17-content-counter.md) §2.6.

Because it precedes the `masterEnabled` and `pauseUntil` returns, counting keeps
working while blocking is off, paused, or the platform is disabled. Full detail in
[17-content-counter.md](17-content-counter.md).

---

## 7. Config parsing — `DetectionConfig`

`platforms_config.json` (pushed by Dart, bundled fallback
`assets/config/platforms_config.json`) is parsed once per `reload()` into a
package-indexed map for O(1) hot-path lookup (`platformsFor(pkg)`).

Shape parsed (`DetectionConfig.parse`):

```
featuredApps: {
  <appKey>: {
    packageName: "com.instagram.android",   // defaults to appKey
    platforms: [
      {
        platformId: "ig_reel",
        detectionType: "LEGACY|CALIBRATION|OVERLAY|MANUAL|NONE",  // default LEGACY
        premiumExclusive: false,
        defaultStatus: true,
        detectors: {
          "FINDBYID" | "VIEWID_RES_NAME" | "CONT_DESC" | "BROWSER": {
            identifiers: [...],
            supportedBlockModes: [...],
            defaultBlockMode: "PRESS_BACK",   // default
            priority: 0,
            haltOnDetect: true,               // default
            childNodeLimit: -1                // parsed, not used by matches()
          }
        }
      }
    ]
  }
}
```

- The **detector key** is the `viewDetector` kind (map key), and its value object
  holds the rule fields.
- Detectors are sorted by `priority` ascending (`detectors.sortBy { it.priority }`).
- Any parse failure returns `DetectionConfig.EMPTY` (fail-safe: no detection
  rather than a crash). Missing `featuredApps` also yields `EMPTY`.

---

## 8. Timing constants (single source of truth)

Native constants live in the `DetoxoAccessibilityService` companion object and are
**mirrored** in Dart (`EngineTimings` in `lib/core/constants/app_constants.dart`)
for UI affordances and Dart-side policy — the hot path itself runs in Kotlin.

| Constant | Native value | Dart mirror (`EngineTimings`) | Purpose |
|----------|--------------|-------------------------------|---------|
| `THROTTLE_MS` | 150 ms | `eventThrottle = 150 ms` | Per-package event throttle. |
| `BLOCK_DEBOUNCE_MS` | 1200 ms | `blockDebounce = 1200 ms` | Min gap between block actions. |
| `BACK_RATE_LIMIT_MS` | 1100 ms | `backRateLimit = 1100 ms` | Simulated-Back rate limit. |
| `MAX_NODES` | 12000 | `maxNodeTraversal = 12000` | DFS node cap in `matches`. |
| `CONSCIOUS_TICK_MS` | 1000 ms | — | Conscious accountant cadence. |
| `WATCH_STALE_MS` | 2500 ms | — | "Still watching" window. |
| `CONSCIOUS_MAX_STEP_MS` | 5000 ms | — | Cap on a single bank-drain step. |
| `BLOCK_VIBRATION_MS` | 60 ms | — | Block haptic one-shot. |
| — | — | `oneReelOverlayGrace / oneReelOverlayPoll = 500 ms` | One-reel overlay grace/poll (overlay module, not this file). |
| — | — | `hardBlockGrace = 10 s` | Hard-block grace after a kill/lock. Dart-side constant only; **no** counterpart exists in `DetoxoAccessibilityService.kt` — treat the native enforcement as a follow-up/swap-in. |

> **Sync note:** whenever a native timing changes, update the matching
> `EngineTimings` field (and vice-versa). The `oneReelOverlayGrace/Poll` and
> `hardBlockGrace` values are only defined on the Dart side today; the one-reel
> overlay behaviour is documented in the overlay module, and `hardBlockGrace`
> currently has no native reference in the detection service.

---

## 9. Events emitted (via `ServiceEventBus`)

The engine multiplexes onto the single EventChannel
(`com.errorxperts.detoxo/events`) through `ServiceEventBus.post(type, payload)`.
Types this file emits:

| Type | Payload | When |
|------|---------|------|
| `serviceStatus` | `{running}` | Connect / interrupt / unbind / destroy. |
| `blocked` | `{package, platformId, mode, today, total}` | A reel block fired in `onDetected`. |
| `webBlocked` | `{host, mode:"PRESS_BACK", today, total}` | A blocked host bounced (browser branch). |
| `consciousState` | `{bankMs, maxBankMs, watching, blocked, active}` | Each Conscious tick / sync. |
| `reelSessionState` | `{consumed, allowance, blocked, active}` | Each One Reel / Unblock allow, block, or arm (§5.3). |
| `detection`, `foregroundChanged`, `contentCounted` | — | Emitted by sibling modules (counter / foreground tracking), not shown here. |

Block/web counters are date-keyed `dd-MM-yyyy` in `ConfigStore`
(`recordBlock` + `blockStats`, `recordWebBlock` + `webBlockStats`) and persisted
to SharedPreferences file `detoxo_engine_prefs`.

---

## Source files

- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DetectionConfig.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt`
- `lib/core/constants/app_constants.dart`
