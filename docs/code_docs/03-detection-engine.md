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
| `onServiceConnected()` | Sets the `instance` singleton, constructs `ConfigStore`, marks `serviceEverConnected`, calls `reload()`, calls `startAsForeground()`, schedules the protection watchdog job, posts `serviceStatus {running:true}`. |
| `reload()` | Re-parses `DetectionConfig.parse(store.platformsConfigJson)`, refreshes the protected + blocked-app package caches, the default-launcher package **and the hot-path settings mirrors** (`masterOn`, `pausedUntil`, `activePlan`, `enabledPlatformIds` — see §2.2), force-flushes any accrued-but-unwritten Conscious bank then re-reads it into the cache (§5.2), refreshes the web blocklist + adult flag, calls `syncConscious()` **and `syncReelBubble()`** (pushes the One Reel / Unblock "reels left" count to the counter bubble — §5.3). Invoked whenever Dart pushes new config/settings. |
| `onInterrupt()` | Posts `serviceStatus {running:false}`. |
| `onUnbind()` / `onDestroy()` | Clears `instance`, stops the Conscious accountant, force-flushes the cached Conscious bank (§5.2), disposes the content counter (flushing pending usage time), posts `serviceStatus {running:false}`. |
| `onTaskRemoved()` | Re-arms the foreground service if the user swipes the app away. The service itself is bound by the system, so it survives regardless. |

`instance` is a `@Volatile` companion singleton; `isRunning()` returns
`instance != null`. The `CommandHandler` reaches the live service (e.g. for
`performBack`, `consciousState`, content-counter toggles) through this singleton.

Config is held as a `@Volatile var config: DetectionConfig` so the hot event path
reads a consistent snapshot while Dart can swap it via `reload()`.

Status notification: channel id `detoxo_protection_channel`, name
`"Detoxo Service Status"`, `IMPORTANCE_LOW`, `NOTIF_ID = 1125`. The service **is
a foreground service** — `startAsForeground()` calls `startForeground(...)`
(`FOREGROUND_SERVICE_TYPE_SPECIAL_USE` on API 34+) with that notification — see
[04-native-android-layer.md](04-native-android-layer.md) §2.

---

## 2. `onAccessibilityEvent` — the hot loop

Every event flows through one ordered gauntlet of guards. Order matters: the
counting pass is deliberately placed **before** any block/gate logic so counting
never depends on blocking being active.

```
onAccessibilityEvent(event):
  pkg = event.packageName            ; return if null
  matchMemo.clear()                  ; per-event detector-match memo (see §4)
  pkgProtected = isProtected(pkg)    ; privacy-protected app? (cached set)
  if WINDOW_STATE_CHANGED:           ; track foreground for Conscious + counter
      foregroundPkg = pkg
      checkRuleBoundary(now)         ; posts ruleBoundary once nextBoundaryMs has passed (see 27)
      if pkgProtected or no platforms for pkg: lastReelAtMs = 0  ; end "watching"
      if pkg is not the IME: contentCounter.onForegroundChanged(pkg, !pkgProtected && isReelBearing)
  if pkgProtected or isProtected(foregroundPkg): return  ; PRIVACY GUARD (see 24)
  if pkg == our own package: return
  if contentCounter.isEnabled: countContent(event, pkg)   ; side-effect-free
  if nudge.enabled: tickNudge(now)                         ; soft nudge — advisory, never blocks
  if !masterOn: return                                     ; master kill-switch (cached)
  appUnblocked = unblocks.hasAny(APP) and unblocks.isUnblocked(APP, pkg, elapsed)  ; M8 (see 31)
  if !appUnblocked and pkg in blockedApps and (windowState or pkg==foregroundPkg):
      onAppBlocked(pkg); return                            ; whole-app block — ABOVE Pause (see 06)
                                                           ; a grant lifts it; a Pause does not
  ; strict rules run HERE, above the gate — and never read `appUnblocked` (see 27, 31)
  if now < pausedUntil: return                             ; Pause window (cached)
  if !appUnblocked and ruleEngine.hasPackageRules() and (windowState or pkg==foregroundPkg):
      rule = ruleEngine.blockingForPackage(pkg, now)       ; schedules / spent limits — BELOW Pause
      if rule: onAppBlocked(pkg, rule.reason); return
  if plan==ONE_REEL and event==VIEW_SCROLLED and pkg has platforms:
      page = ReelTracker.settledPage(fromIndex, toIndex)   ; pager page / NO_INDEX / IGNORE
      if page != IGNORE and (page == NO_INDEX or page != oneReelPage):
          lastScrollAtMs = now; oneReelPage = page         ; capture reel advance BEFORE throttle
  ── per-package throttle (THROTTLE_MS = 150) ──
  if BrowserUrlExtractor.isBrowser(pkg):                   ; web blocking branch (blocklist OR host rules)
      handleBrowser(pkg, paused) on window/content change; return  ; bails unless the FOCUSED root's
                                                           ; package == pkg (split-screen). Runs during
                                                           ; a Pause only for STRICT host rules (M8)
  platforms = config.platformsFor(pkg)   ; return if empty
  for each platform (LEGACY/OVERLAY, enabled):
      for each detector (FINDBYID / VIEWID_RES_NAME):
          if matches(root, event, detector):
              rule = ruleEngine.blockingForPlatform(platformId, now, reelTimeTodayMs)  ; schedule / daily reel limit (see 27)
              if rule: onDetected(pkg, platformId, detector, rule.reason); continue/return
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
5b. **Soft nudge** — `if (nudge.enabled) tickNudge(nowMs)`. Advances the
   Android-free `NudgeTracker` dwell machine and, at a threshold, raises the
   bottom card. Sits here for the counter's reason: it is **advisory**, so it
   runs above the master switch and the Pause gate — the user asked to be told
   how long they have been somewhere, which is true whether or not blocking is
   on. It never returns, never presses BACK and never touches block state, and
   it walks no nodes: it reads a package name off an already-dispatched event.
   Driven from **every** event, not only `WINDOW_STATE_CHANGED`, because the
   idle timeout needs a dense heartbeat; the package it is handed is the
   separately latched `nudgeForegroundPkg` (moved only on real window changes,
   and never to the IME). Full design in [30-soft-nudge.md](30-soft-nudge.md).
6. **Master switch** — `if (!masterOn) return` (the cached mirror of
   `store.masterEnabled`, see §2.2). Default `true`.
7. **Custom whole-app block** — `if (!appUnblocked && pkg in blockedApps && (windowState || pkg == foregroundPkg)) { onAppBlocked(pkg); return }`.
   The user locked this entire app (`pushAppBlocklist`): HOME bounce with its own
   1200 ms debounce, before the throttle. **Checked ABOVE the Pause gate** (still
   below the master switch): a Pause taken for reels must not quietly unlock a
   fully-locked app.

   **`appUnblocked` (M8)** is resolved once, right after the master switch, from
   `UnblockRegistry.isUnblocked("APP", pkg, elapsedRealtime)` — behind
   `hasAny(TYPE_APP)`, so a user with no grants pays one volatile read and no
   `elapsedRealtime` call. A per-target grant **does** lift this lock and the
   non-strict rules arm at step 9; that is the whole point of "Unblock Instagram
   for 15 minutes". It never reaches the strict arm below
   ([31-locked-rules-and-unblock.md](31-locked-rules-and-unblock.md) §2).
   Anchored to the foreground — a backgrounded blocked app's notification events
   carry its packageName and must never bounce the user out of an unrelated app;
   the `foregroundPkg` leg still bounces someone already inside the app when the
   block lands. Full semantics in
   [06-app-and-web-blocker.md](06-app-and-web-blocker.md).
8. **Pause gate** — `if (System.currentTimeMillis() < pausedUntil) return`
   (cached mirror of `store.pauseUntil`). Clock-based; suspends reel/web
   blocking (whole-app locks above stay enforced) regardless of the pushed plan
   name (see §5). One clock read (`nowMs`) is taken once per event and reused by
   the boundary check, this gate, the rules arm and the throttle.

   **Strict rules run just ABOVE this gate** (EVO-030): `if (ruleEngine.hasStrictRules()
   && (windowState || pkg == foregroundPkg))` → `blockingForPackage(pkg, nowMs,
   strictOnly = true)`. A strict rule is the per-rule opt-out from "a Pause lifts
   rules"; the gate itself only returns early when there is no strict rule targeting a
   **reel surface**, because that decision is made inside the detector loop.

   **This arm deliberately does not read `appUnblocked`** — and a rule the user
   marked *Locked* is pushed as strict, so nothing a per-target grant can do
   lifts one. That absence is the guarantee: there is no wire flag saying "this
   grant is privileged", so no Dart bug can mint one. The wall it raises sets
   `offersUnblock = false`. The only relief is an **override**, which spends
   quota and is applied by splitting that rule's own windows before the push.
9. **Rules arm** — `if (!paused && !appUnblocked && ruleEngine.hasPackageRules() && (windowState || pkg
   == foregroundPkg))` ask `RuleEngine.blockingForPackage(pkg, nowMs)`: an open schedule
   window or a **spent** daily limit covering this app → `onAppBlocked(pkg, rule.reason,
   rule.activeUntil(nowMs))` (HOME bounce, the wall with the rule's reason and its
   release time, `blocked{platformId:"rule"}`). **Checked BELOW the Pause gate by
   design** — a Pause lifts non-strict rules the way it lifts reel and web blocking;
   App Blocker locks (step 7) stay unconditional. Foreground-anchored and before the
   throttle for the same reasons as step 7. The guard is `hasPackageRules()`, **not**
   `hasAnyRules()`: a user with zero rules but a global Daily Limit still has the
   synthetic meter entry, so `hasAnyRules()` is true for them and this arm would run on
   nearly every foreground event for nothing. A **pending** limit entry (budget not yet
   spent) never blocks — native only measures it. Full design in
   [27-rules-engine.md](27-rules-engine.md).
10. **Per-package throttle** — see §3. Immediately *before* this throttle, under the
    `ONE_REEL` plan a `TYPE_VIEW_SCROLLED` from a monitored app stamps
    `lastScrollAtMs` — a throttled scroll would hide a reel advance and leak the next
    reel past the allowance (see §5.3).
11. **Browser branch** — if the package is a known browser, run web blocking
    (only on `WINDOW_STATE_CHANGED` / `WINDOW_CONTENT_CHANGED`, and only if the
    blocklist has rules **or** the rules snapshot names a domain) and `return`.
    Browsers carry no reel surfaces, so the reel path is skipped either way.
    Detailed in [06-app-and-web-blocker.md](06-app-and-web-blocker.md).

    **M8 re-gated it for a Pause**: the arm now runs when
    `!paused || ruleEngine.hasStrictHostRules()`, passing `paused` into
    `handleBrowser`, which then skips the user's own blocklist entirely and
    narrows the rules pass to `strictOnly`. That closes EVO-030's documented
    website gap — a strict (and therefore a locked) rule's sites used to be
    opened for free by a two-minute Pause. Everything a Pause always lifted
    still lifts.
12. **Reel detection** — iterate the package's platforms/detectors (§4); on a match
    the **rules platform arm** runs first (`RuleEngine.blockingForPlatform` — a
    schedule on this reel feed, or the daily reel limit whose native meter
    `ContentCounter.timeTodayMs(now)` has reached the limit → `onDetected(...,
    ruleReason, ruleUnlocksAtMs)` regardless of the plan), else apply the Conscious
    allowance check (§5.2) **or the One Reel / Unblock gate (§5.3)**, then execute the
    block (§4.4). While a Pause is live the loop is narrowed to `strictOnly` and every
    plan check below it is skipped, so a Pause keeps lifting everything it always did.

    **M8 splits the rule resolve in two.** A `strictOnly = true` pass runs
    FIRST (gated on `hasStrictPlatformRules()`), mirroring the package arm above
    the gate, and a hit blocks with `offersUnblock = false` without consulting
    any grant. Only then — and only below `if (paused) continue` — does the
    general pass run. The loop cannot trust the first match's `strict` flag
    instead: `blockingForPlatform` returns the FIRST covering entry and the
    snapshot is ordered by `createdAtMs`, so an older non-strict rule masks a
    newer locked one, and the wall it raises would offer a button whose grant
    then lifts the locked rule for free.

    **`reelUnblocked`** is resolved per platform from
    `UnblockRegistry.isUnblocked("REEL", platformId, …)` and consumed twice: it
    lifts a non-strict rule hit, and it lifts the plan below. The awareness
    counter ran above this whole branch, so a granted reel is still counted —
    and the granted arm clears `lastReelAtMs`, which drops the Conscious
    accountant into its existing "lingering in a reel app" branch: no drain, no
    accrue. Deliberately not a per-package freeze inside `accountConscious` —
    the accountant only knows the package, but a grant names one `platformId`,
    so that would stop the bank draining for every OTHER surface in the same
    app.

### 2.2 Hot-path settings cache

The per-event settings flags are `@Volatile` mirrors on the service — the event
path touches **no SharedPreferences** (same pattern as the `protectedPkgs` /
`blockedApps` caches):

| Field | Mirrors | Read at |
|-------|---------|---------|
| `masterOn` | `store.masterEnabled` | Guard 6 |
| `pausedUntil` | `store.pauseUntil` | Guard 8, Conscious accountant |
| `activePlan` | `store.activePlan` | Plan gates (§5), accountant, `syncReelBubble` |
| `enabledPlatformIds` | `store.enabledPlatforms` | Detector loop (§4.2) |

All four are refreshed in `reload()`. Safe because every settings write goes
through `CommandHandler`, which always follows with `reload()`.

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
keeps its **own** independent throttle map (`lastCountEventByPackage`) at a
slower `COUNT_THROTTLE_MS = 400` (a stage-3 miss on a non-reel screen is a full
DFS, and a reel's dwell is anchored to the scroll event, not to this check);
`TYPE_WINDOW_STATE_CHANGED` bypasses it. Counting and blocking never starve
each other, and the per-event memo (§4) means both passes still share one walk.
The counting pass additionally **backs off the stage-3 DFS** after a miss
(EVO-021): a per-package `countMisses` counter cycles `0..DFS_SKIP = 4` and the
DFS runs only at 0 — stages 1–2 still run every check. A shallow result comes
from `matches(..., deep = false)` and is never memoised, so the block pass
always gets the full three stages.

---

## 4. The 3-stage view-id detection (`matches`)

`matches(root, event, detector, deep = true)` is the verified detection primitive
shared by both the block path and the counting path — and it is called through
**`matchesMemo`**, a per-event memo (`matchMemo.getOrPut(detector) { matches(...) }`,
cleared at the top of every event): the counting pass and the block pass test the
same detectors against the same window, so the second pass becomes map lookups
instead of a second full tree walk. Events are delivered serially on the main
thread, so no locking.

> `ponytail:` the memo is keyed by **detector only**, while each pass obtains its
> own `rootInActiveWindow` — the block pass can reuse a result computed against
> the counting pass's snapshot, microseconds stale. Accepted ceiling; the upgrade
> path is threading one root through both passes.

A detector carries a list of `identifiers` (resource-id fragments). Two detector
kinds are honoured:

- **`FINDBYID`** — the id is package-qualified: the target is `"$pkg$id"`
  (e.g. `com.instagram.androidid/clips_video_container`).
- **`VIEWID_RES_NAME`** — the id is used **verbatim** as the target.

The fully-qualified `targets` list is `DetectorRule.qualifiedIds`, built **once
at config parse** (`DetectionConfig.parsePlatform(p, pkg)`: `"$pkg$id"` for
`FINDBYID`, the identifiers verbatim for `VIEWID_RES_NAME`) — stage 3 visits up
to 12000 nodes, and a per-node (later per-call) `"$pkg$id"` concat was
measurable allocation churn on the hottest path. Every positive match is gated
on `isVisibleToUser` so an off-screen/recycled node never triggers a block.
`matches(root, event, detector, deep = true)`: `deep = false` (the counting
pass's back-off, §3) returns after stage 2 and must not be memoised.

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
var found = false
while (deque.isNotEmpty() && i < MAX_NODES && !found) {
    val node = deque.removeLast()
    i++
    val resName = node.viewIdResourceName
    if (resName != null && resName in targets && node.isVisibleToUser) {
        found = true
    }
    if (!found) {
        for (c in node.childCount - 1 downTo 0) {
            node.getChild(c)?.let { deque.addLast(it) }
        }
    }
    if (node !== root) node.recycleSafe()
}
while (deque.isNotEmpty()) {
    val node = deque.removeLast()
    if (node !== root) node.recycleSafe()
}
return found
```

Children are pushed in reverse (`childCount-1 downTo 0`) so that popping from the
tail visits them left-to-right. The counter `i` caps the walk at 12000 nodes,
bounding worst-case latency on pathological trees. (`DetectorRule.childNodeLimit`
is parsed from config but is **not** currently consulted in `matches` — the fixed
`MAX_NODES` governs.)

**Node recycling.** Every node `matches()` obtains — the stage-1 `event.source`,
stage-2 lookup hits, and every DFS child (never the caller-owned `root`) — is
released via the `recycleSafe()` extension (`engine/NodeRecycling.kt`): a no-op
on API 33+ (where `recycle()` itself became a no-op), an exception-swallowing
`recycle()` below. Unrecycled nodes were a steady native-heap leak on the
hottest path; `BrowserUrlExtractor` uses the same extension.

The **obtained roots** are recycled too: all five `rootInActiveWindow` obtain
sites — the event loop, `countContent`, `handleBrowser`, and the
`performBackInternal` / `lockScreen` protected-window checks (both via the
`activeWindowProtectedNow()` helper, which obtains a fresh root, checks it, and
recycles it before returning) — release the root via `recycleSafe()` in a
`try/finally`.

### 4.2 Platform / detector selection

For the reel path, only platforms whose `detectionType` is `LEGACY` or `OVERLAY`
are acted on (`CALIBRATION`/`MANUAL`/`NONE` are skipped). Enable/disable is
resolved against `enabledPlatformIds` (the cached mirror of
`store.enabledPlatforms`, §2.2):

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

Since the block screen shipped ([25](25-block-screen.md)), every block site raises the
intervention wall **after** its `ServiceEventBus.post` and **before** its navigation, inside the
same debounced region: `onDetected` (skipped for mode `NONE`), the Conscious accountant's
drain-to-empty boot, `onAppBlocked`, and `handleBrowser`. The wall never replaces the BACK /
HOME below — with no overlay grant or the wall switched off, `raiseWall` returns `false` and the
site shows its legacy toast instead. The pseudocode below is unchanged apart from that call.

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
| `PRESS_BACK` (default) | `performGlobalAction(GLOBAL_ACTION_BACK)` via `pressBackWithRateLimit()` | Rate-limited (§4.5). No wall. |
| `BLOCK_SCREEN` | Back press **plus the block screen** ([25](25-block-screen.md)) | A wall policy, not a navigation: no detector lists it in `supportedBlockModes`, so `resolveBlockMode` yields `PRESS_BACK` and `overlay/WallPolicy.reelWall(store.defaultBlockMode, mode, ruleReason)` reads the *stored* choice to raise the wall. The only mode that walls a plan block. |
| `KILL_APP` | Back, then `ActivityManager.killBackgroundProcesses(pkg)` | Best-effort; catches throwables. No wall. |
| `LOCK_SCREEN` | Back, then device-admin `DevicePolicyManager.lockNow()` | Only if admin active (`admin/DetoxoDeviceAdminReceiver`). |
| `NONE` | No-op | `onDetected` runs `recordBlock`/emit *before* the `when`, so a `NONE` detector still records the stat and emits a `blocked` event but performs no navigation — and raises **no block screen** (a wall over a still-playing reel would be a trap). |

**`resolveBlockMode(detector)`** picks the mode:

1. Take the user's `store.defaultBlockMode`. If it isn't `NONE` **and** the
   detector either lists no `supportedBlockModes` or explicitly supports it → use it.
2. Otherwise use the detector's first supported non-`NONE` mode.
3. Otherwise fall back to the detector's `defaultBlockMode`, defaulting to
   `PRESS_BACK` when blank.

**Wall rule (`overlay/WallPolicy`).** A reel block raises the block screen only when the user's
stored mode is `BLOCK_SCREEN` **or** the block is *forced* — `WallPolicy.forced(reason, plan,
bankMs)`: a `DAILY_LIMIT` or `SCHEDULE` reason, or a `PLAN` block under Conscious with the bank at
zero (EVO-054/055) — and never over a `NONE` navigation. The Appearance switch
(`BlockScreenStyleSpec.enabled`) is skipped per `WallPolicy.bypassesSwitch(payload, chosenMode)`:
every forced wall, and a reel wall in the `BLOCK_SCREEN` mode; the decision is made inside
`BlockScreenOverlay.show` from the payload and `store.defaultBlockMode`, so a style rebuild of a
standing wall agrees with the raise. App-lock and website walls answer to the switch unless forced.
When a reel wall is wanted but cannot show (no overlay grant) the site toasts `toast_blocked`
(EVO-056), and the `blocked` event carries `wall: Boolean` (EVO-057). `pushSettings` whitelists
`defaultBlockMode` to `BlockingMode`'s wire values. Pinned by `overlay/WallPolicyTest`.

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
if (System.currentTimeMillis() < pausedUntil) return   // cached mirror of store.pauseUntil
```

`pauseUntil` is epoch-millis (0 = not paused). While the window is open,
**reel and web blocking are suspended** — but custom whole-app locks stay
enforced, because their branch sits *above* this gate (§2.1 step 7): a Pause
taken for reels must not quietly unlock a fully-locked app. When the clock
passes `pauseUntil`, the underlying active plan resumes automatically. This is
intentionally decoupled from the plan name so it works regardless of which plan
is set.

### 5.2 Conscious — earn-as-you-abstain token bank

Conscious lets reels play *while the user has banked allowance*, then boots them
when the bank empties. Durable state lives in `ConfigStore`:

| Field | Default | Meaning |
|-------|---------|---------|
| `consciousBankMs` | 0 | Durable copy of the banked allowance (0..max), millis — the **live** value is the service's cached `consciousBank` (write-batched, below), so this trails it by at most ~5 s while the accountant runs. |
| `consciousMaxBankMs` | 600 000 (10 min) | Bank ceiling. |
| `consciousEarnDivisor` | 10 (≥1) | Refill rate: `bank += elapsed / divisor` while abstaining. |

The tick anchor (`consciousAnchorMs`) is a **runtime-only field on the service**
— it is *not* persisted (ConfigStore's former anchor property and prefs key were
deleted); a service restart simply re-anchors to now in `syncConscious()`.

**Bank write batching.** The 1 Hz accountant used to do two prefs `.apply()` per
tick (anchor + bank ≈ 172k writes/day in Conscious). The bank now lives in a
`@Volatile consciousBank` cache on the service; `flushConsciousBank()` writes it
through to `store.consciousBankMs` at most once per `CONSCIOUS_FLUSH_MS`
(**5000 ms**), and is **forced** when the bank empties (the block boundary is
durability-critical — it's what keeps a service restart blocked), on plan stop
(`syncConscious`), inside `reload()` (settle before re-reading, so a config push
mid-tick can't roll the cache back to a stale stored value), and in
`onUnbind`/`onDestroy`.

> `ponytail:` ≤ 5 s of earned bank can be lost on a hard process kill. Accepted
> ceiling for dropping ~172k daily prefs writes.

**In the detection loop**, when a reel matches under Conscious:

```kotlin
if (activePlan == PLAN_CONSCIOUS && consciousBank > 0L) {   // both cached — no prefs read
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
retroactively credited; the persisted bank carries over); stopping (leaving the
plan) force-flushes the cached bank.

The explicit fresh-start reset arrives via the service hook
**`onConsciousBankReset()`** (called by `CommandHandler`'s `resetConsciousBank`
arm after it zeroes the store): it drops the cached bank *and* the pending
unflushed dirt — so a pending accrual can't resurrect the zeroed value — then
`reload()`s.

`accountConscious()` — one step:

```
if plan != CURIOUS: return                             // cached activePlan
if consciousDate != today: consciousDate = today; bank = 0; flush(force)  // daily fresh start —
                                                       // forced: date was just written durably, a
                                                       // hard kill must not pair it with yesterday's bank
elapsed = clamp(now - anchor, >=0); anchor = now      // advance first, always (runtime anchor)
if !masterOn: flush(); emit; return                    // freeze (no drain/accrue)
if now < pausedUntil: flush(); emit; return            // freeze during a live Pause (Conscious base)
if isProtected(foregroundPkg):                         // privacy: freeze + drop stale watching
    lastReelAtMs = 0; flush(); emit; return            // never BACK-press into a protected app
watching = (now - lastReelAtMs) < WATCH_STALE_MS (2500 ms)
inReelApp = foregroundPkg has any configured platform
if watching:
    bank -= min(elapsed, CONSCIOUS_MAX_STEP_MS=5000)   // cap a delayed tick
    if bank <= 0: bank = 0; lastReelAtMs = 0; pressBackWithRateLimit()  // boot
else if !inReelApp:
    bank = min(bank + elapsed / earnDivisor, maxBank)  // accrue only truly off-reels
// else lingering on a reel app, detection quiet → hold steady
consciousBank = max(bank, 0) (mark dirty if changed)   // cache, NOT a prefs write
flushConsciousBank(force = bank == 0)                  // write-through ≤ once per 5 s;
emit consciousState                                    // the empty-bank boundary flushes NOW
```

Key nuances:
- **Daily reset** — the bank is re-earned each day: the first tick on a new day
  key (`ConfigStore.consciousDate`) zeroes any carried balance, so an overnight
  abstain can't stockpile a free 10-minute morning allowance.
- **Drain 1:1** while watching; **accrue at `1/divisor`** only when the foreground
  app has no configured reel platforms at all.
- A **paused reel** (reel app foreground, detection gone quiet) neither drains nor
  refills — it holds steady, so pausing a video can't farm allowance.
- A **live Pause** window (`now < pauseUntil`) **freezes** the bank, mirroring the
  master-off freeze: when Conscious is the base mode being paused, every reel is
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
  the same guard as a fail-closed backstop, plus the `activeWindowProtected`
  window anchor (the active window's own package), which also gates every
  `rootInActiveWindow` tree walk — immune to a `foregroundPkg` left stale by a
  service reconnect or clobbered by a transient IME/system window (see
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
after it's been watched for `MIN_VIEW_MS = 2000 ms`** — deliberately longer than
the awareness counter's 1 s "seen" dwell, because an allowance is spent on reels
*watched* — so a quick flick-through (<2s) doesn't count, and a **single looping
reel costs at most one count** — a `reelViewCounted` latch prevents re-counting the
same view. Reels are still **scroll-delimited** (consecutive reels share the same
continuously-visible view-id, so `matches()` fires the whole time a reel is up),
but only a scroll that **lands on a different pager page** stamps the advance:
`ReelTracker.settledPage(event.fromIndex, event.toIndex)` is compared with the
runtime `oneReelPage` — a multi-item list (comments sheet) is never an advance, a
snap-back onto the same page is not, an unindexed view (`−1`) always is. And a
stamped advance only counts as an **advance to a new reel** once **≥ 2s have
passed since the last count** (`lastReelCountMs`). Together these **keep in-reel
scrolls** (opening comments/captions/carousels) from burning the allowance or
blocking the reel you're still watching. The capture into the runtime `@Volatile
lastScrollAtMs` happens **before** the 150 ms throttle (§2.1 step 7); a scroll
swallowed by the throttle would hide the advance. `oneReelPage` resets with the
other dwell fields (`armReelSession`, leaving the reel app).

In the detector loop, when a reel matches under `ONE_REEL`:

```kotlin
if (activePlan == PLAN_ONE_REEL && allowReelOrBlock(now)) return  // allow (cached plan)
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

> `ponytail:` reel identity here is the pager page at event time (no settle window,
> unlike the awareness counter's `ReelTracker`) plus the 2s dwell. A spurious page
> change **> 2s** after a count can still be misread as an advance, and a fast
> advance **within 2s** of a count is absorbed into the current reel (a small
> leniency — safer than false-blocking the reel you're still watching). Accepted
> ceiling; the upgrade path is to drive this gate from `ReelTracker` too.
> Full Dart/UI side in [05-plans-pause-conscious.md](05-plans-pause-conscious.md) §7.

---

## 6. Content counting is decoupled from blocking

`countContent(event, pkg)` runs before the master/pause gates and is strictly
**side-effect-free** with respect to blocking: it never presses back and never
reads/writes block state. It:

1. Accrues **whole-app usage time** for monitored apps via
   `contentCounter.onAppActivity(pkg)` (see below), before the throttle.
2. On `TYPE_VIEW_SCROLLED`, forwards `contentCounter.onScroll(pkg, fromIndex,
   toIndex, scrollDeltaY, isPager)` — the pager's own visible-page range is the
   reel's identity; `ReelTracker` settles and classifies it (see
   [17-content-counter.md](17-content-counter.md) §2.3). `isPager` comes from
   `pagerVerdict()` (EVO-024): `null` unless a platform of this package declares
   a `pagerViewId` ([02](02-detection-config-schema.md) §1.3), else one
   `event.source` read compared against the declared id. A
   `Log.isLoggable`-gated line logs the raw fields (incl. `pager=`) for per-app
   calibration.
3. Applies its **own** per-package throttle (`lastCountEventByPackage`,
   `COUNT_THROTTLE_MS = 400`; `TYPE_WINDOW_STATE_CHANGED` bypasses it).
4. Reuses the read-only `matches()` walk — through the shared per-event
   `matchesMemo` when the check is deep, so the block pass that follows never
   re-walks a detector this pass already tested; after a miss the next
   `DFS_SKIP = 4` checks are shallow (stages 1–2, memo bypassed) — against
   **reel** platforms only
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
undercounts truly passive, event-quiet playback. Deltas are **batched in memory**
(`pendingUsageMs`) and flushed via `ContentCounterStore.recordUsage` into
`cc_time_today` / `cc_time_total` at ≥ 5 s / app switch / protected-foreground /
snapshot / dispose — not one prefs write per event. This
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
| `THROTTLE_MS` | 150 ms | `eventThrottle = 150 ms` | Per-package event throttle (block path). |
| `COUNT_THROTTLE_MS` | 400 ms | — | Counter surface-check cadence (own map; `WINDOW_STATE_CHANGED` bypasses). |
| `DFS_SKIP` | 4 | — | Counting-pass checks that skip the stage-3 DFS after a miss (EVO-021); the block path never skips. |
| `BLOCK_DEBOUNCE_MS` | 1200 ms | `blockDebounce = 1200 ms` | Min gap between block actions. |
| `BACK_RATE_LIMIT_MS` | 1100 ms | `backRateLimit = 1100 ms` | Simulated-Back rate limit. |
| `MAX_NODES` | 12000 | `maxNodeTraversal = 12000` | DFS node cap in `matches`. |
| `CONSCIOUS_TICK_MS` | 1000 ms | — | Conscious accountant cadence. |
| `WATCH_STALE_MS` | 2500 ms | — | "Still watching" window. |
| `CONSCIOUS_MAX_STEP_MS` | 5000 ms | — | Cap on a single bank-drain step. |
| `CONSCIOUS_FLUSH_MS` | 5000 ms | — | Batch Conscious-bank prefs writes to ≤ 1 per interval (§5.2). |
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
| `serviceStatus` | `{running}` | Connect / interrupt / unbind / destroy. The last payload is **sticky** — replayed to a late Dart subscriber ([04](04-native-android-layer.md) §4). |
| `blocked` | `{package, platformId, mode, today, total, reason}` | A reel block fired in `onDetected`, or a whole-app block in `onAppBlocked` (`mode:"HOME"`; `platformId:"app_block"` for an App Blocker lock, `"rule"` for a rule — [06](06-app-and-web-blocker.md), [27](27-rules-engine.md)). `reason` is `PLAN` \| `APP_BLOCK` \| `SCHEDULE` \| `DAILY_LIMIT`. |
| `ruleBoundary` | `{atMs}` | The pushed `nextBoundaryMs` passed (a rule window opened or closed) — posted once from the `WINDOW_STATE_CHANGED` block or the watchdog tick, then zeroed ([27](27-rules-engine.md) §5). |
| `webBlocked` | `{source:"RULE"\|"ADULT", mode:"PRESS_BACK", today, total, host?}` | A blocked host bounced (browser branch). `host` only for RULE hits — adult-list blocks are never named (EVO-018). |
| `consciousState` | `{bankMs, maxBankMs, watching, blocked, active}` | Each Conscious tick / sync. |
| `reelSessionState` | `{consumed, allowance, blocked, active}` | Each One Reel / Unblock allow, block, or arm (§5.3). |
| `contentCounted` | — | Emitted by the sibling `ContentCounter` module, not shown here. |
| `nudgeShown` | `{package, elapsedMs, thresholdMs}` | A soft-nudge card actually attached (`showNudge`). Only the threshold band reaches Firebase; the package stays on the device ([30](30-soft-nudge.md)). |

Block/web counters are date-keyed `dd-MM-yyyy` (via the shared
`DateKeys.today()` formatter) in `ConfigStore` (`recordBlock` +
`blockStats(dateKey)`, `recordWebBlock` + `webBlockStats(dateKey)`, both with
read-time day rollover — [09](09-persistence-data-model.md) §2.1) and persisted
to SharedPreferences file `detoxo_engine_prefs`. The pushed platforms config
itself lives in the separate `detoxo_platforms_config` file so hot-path counter
writes don't re-serialise it.

---

## Source files

- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DetectionConfig.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ReelTracker.kt` — `settledPage()`, shared with the One Reel gate; the counting rule itself is [17](17-content-counter.md)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/RuleEngine.kt` — the rules snapshot the two rule arms and the boundary check consult ([27](27-rules-engine.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DateKeys.kt`
- `android/app/src/main/res/values/strings.xml` — block toast (`toast_blocked`, now the fallback when the block screen cannot be raised) + the block screen's `wall_*` copy + FGS notification strings
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenOverlay.kt`, `BlockScreenRenderer.kt` — the intervention wall the block sites raise ([25](25-block-screen.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NudgeTracker.kt` — the soft-nudge dwell machine `tickNudge` drives ([30](30-soft-nudge.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/NudgeOverlay.kt` — the card it raises ([30](30-soft-nudge.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NodeRecycling.kt`
- `lib/core/constants/app_constants.dart`
