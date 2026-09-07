# Native Android Layer

Everything under `android/app/src/main/` that is Kotlin, manifest, or `res/xml`. This is the platform half of Detoxo: the AccessibilityService that does the actual detection and blocking, the MethodChannel/EventChannel bridge to Dart, the two broadcast receivers (boot, device-admin), the overlay bubble, the home-screen widget provider, and the manifest / resource declarations that glue them together.

Android is the **only** supported platform. iOS has no AccessibilityService equivalent, so the engine is gated off there (see the Dart-side `PlatformCapabilities`); this doc is Android-only by construction.

- Native package root: `android/app/src/main/kotlin/com/errorxperts/detoxo/`
- Namespace / applicationId: `com.errorxperts.detoxo` (`android/app/build.gradle.kts`)
- For the **full wire contract** (every command method, every event `type`, argument shapes, the Dart wrappers), see [18-platform-channel-contracts.md](18-platform-channel-contracts.md). This doc covers the native implementation and how the pieces are wired.
- For the detection algorithm and Conscious/Pause internals, see [03-detection-engine.md](03-detection-engine.md).

---

## 1. Process & lifecycle model

There is **one** process. The AccessibilityService, the Flutter engine, the command handler, the overlay bubble, and the widget provider all run in the app's main process — there is no separate `:as_process` or remote service. The manifest `<service>` for the engine carries no `android:process`, so it is co-located with `MainActivity`.

Why co-located: while the UI is alive, the service can push events straight to the live Flutter engine over an in-process bridge ([`ServiceEventBus`](#4-serviceeventbus--the-in-process-event-bridge)); when the UI is dead, the block hot-path is pure Kotlin and keeps working — Dart is simply not in the loop.

```
Flutter UI (Dart)                         Android main process (Kotlin)
────────────────                          ─────────────────────────────
EngineChannel                MethodChannel   CommandHandler ── ConfigStore
  commands  ───────────────▶ /commands  ───▶   (Dart→native)   (SharedPreferences
                                                │                detoxo_engine_prefs)
  events    ◀─────────────── /events    ◀───  DetoxoEventStream
                             EventChannel        ▲
                                                 │  ServiceEventBus.post(...)
                                        DetoxoAccessibilityService  (FGS, main process)
                                          ├─ detection + block hot-path
                                          ├─ ContentCounter → ContentCounterBubble (overlay)
                                          │                 → ContentCounterWidgetProvider (widget)
                                          ├─ WebBlockEngine
                                          ├─ UnblockRegistry
                                          └─ RuleEngine (pushed rules snapshot — 27)
```

`MainActivity` (`MainActivity.kt`) is a `FlutterFragmentActivity` (required by `local_auth`). In `configureFlutterEngine` it wires exactly two channels to the binary messenger:

| Channel | Name | Handler |
|---|---|---|
| MethodChannel | `com.errorxperts.detoxo/commands` | `CommandHandler` |
| EventChannel  | `com.errorxperts.detoxo/events`   | `DetoxoEventStream` |

The activity holds the `CommandHandler` and nulls out its activity reference in `onDestroy` (so permission-launch intents fall back to a `NEW_TASK` context instead of leaking a dead activity).

---

## 2. AccessibilityService (main process + foreground service)

`accessibility/DetoxoAccessibilityService.kt` is both the detection/block engine **and** the app's foreground service. The full detection/block/Conscious algorithm is documented in [03-detection-engine.md](03-detection-engine.md); here we cover only its lifecycle and platform-integration surface.

### Foreground service

On `onServiceConnected` the service sets its static `instance`, marks `ConfigStore.serviceEverConnected = true`, loads config, calls `startAsForeground()`, schedules the protection watchdog job (idempotent — §5), and posts a `serviceStatus {running:true}` event.

`startAsForeground()`:

- Creates notification channel `detoxo_protection_channel` (name **"Detoxo Service Status"**, `IMPORTANCE_LOW`, no badge, description "Focus protection active") on API 26+.
- Builds an ongoing, `PRIORITY_MIN` notification ("Detoxo is active" / "Monitoring and blocking short-form video.", small icon `ic_launcher`). All four user-facing strings come from `res/values/strings.xml` (`fgs_channel_name` / `fgs_channel_description` / `fgs_title` / `fgs_text`), not hardcoded Kotlin.
- Calls `startForeground(NOTIF_ID, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)` on Android 14+ (`UPSIDE_DOWN_CAKE`), else the 2-arg overload.

| Constant | Value |
|---|---|
| `CHANNEL_ID` | `detoxo_protection_channel` |
| Channel name | `Detoxo Service Status` |
| `NOTIF_ID` | `1125` |
| FGS type | `FOREGROUND_SERVICE_TYPE_SPECIAL_USE` (API 34+) |

### Lifecycle callbacks

| Callback | Behaviour |
|---|---|
| `onServiceConnected` | set `instance`, mark `serviceEverConnected`, load config, start FGS, schedule the watchdog job, emit `serviceStatus{running:true}` |
| `onAccessibilityEvent` | the hot-path: content-count pass → master switch → per-target unblock resolve → whole-app-block branch (above the Pause gate) → strict rules → Pause gate → detection → block/Conscious (see [03](03-detection-engine.md)) |
| `onInterrupt` | emit `serviceStatus{running:false}` |
| `onTaskRemoved` | re-arm the FGS so swiping the app away does not kill protection |
| `onUnbind` / `onDestroy` | clear `instance`, stop the Conscious ticker, force-flush the cached Conscious bank, dispose the counter (flushing pending usage time), emit `serviceStatus{running:false}` |

### Hot-path efficiency notes

- **Per-event detector-match memo** (`matchMemo: HashMap<DetectorRule, Boolean>`, cleared at the top of every event): the counting pass and the block pass test the same detectors against the same window — the second pass becomes map lookups instead of a second full tree walk. Events are delivered serially on the main thread, so no locking. (`ponytail:` the memo is keyed by detector only while each pass obtains its own root — sub-ms staleness accepted; upgrade path is threading one root through both passes.)
- **Hot-path settings cache** — `masterOn` / `pausedUntil` / `activePlan` / `enabledPlatformIds` are `@Volatile` mirrors on the service (same pattern as the protected/blocked-app caches), refreshed in `reload()` — the event path reads **no SharedPreferences** for these ([03](03-detection-engine.md) §2.2).
- **Conscious bank write batching** — the 1 Hz accountant used to do two prefs `.apply()` per tick (≈172k writes/day); the bank now lives in a `@Volatile` cache and `flushConsciousBank()` writes at most once per 5 s (`CONSCIOUS_FLUSH_MS`), forced on bank-empty / plan stop / `reload()` / unbind/destroy. The tick anchor is runtime-only (a restart re-anchors to now). Ceiling: ≤5 s of earned bank lost on a hard kill ([03](03-detection-engine.md) §5.2).
- **Precomputed detector targets** — the fully-qualified target-id list is `DetectorRule.qualifiedIds`, built once at config parse, instead of a `"$pkg$id"` concat per DFS node (up to 12000 nodes) or per call.
- **Counting-pass DFS back-off (EVO-021)** — after a miss the counting pass runs stages 1–2 only for the next `DFS_SKIP = 4` checks (memo bypassed, so the block pass still gets a full answer); a hit or a window change resets it. Feed browsing with blocking off went from a full walk every 400 ms to one every 2 s.
- **Hot-path prefs + clock** — `ContentCounterStore.enabled` / `bubbleEnabled` are cached per instance (the service gates every event on `enabled`); `DateKeys.today()` is memoised per wall-clock minute; the bubble remembers a denied `canDrawOverlays` for 5 s instead of a binder round-trip per surface check; `ContentCounter` runs entirely on `uptimeMillis`.
- **Counter surface-check cadence** — the counting pass checks the window at `COUNT_THROTTLE_MS = 400` (block path stays at 150 ms; `WINDOW_STATE_CHANGED` bypasses) because a stage-3 miss on a non-reel screen is a full DFS and nothing about a reel's dwell is anchored to the check — the reel's identity and timing come from the scroll event's own `fromIndex`/`toIndex`, settled and judged by `engine/ReelTracker.kt` on one Handler timer ([17](17-content-counter.md) §2.3).
- **Node recycling below API 33** — `engine/NodeRecycling.kt` adds a `recycleSafe()` extension (no-op on 33+, where `recycle()` became a no-op; swallows double-recycle throws). Used in `matches()` tree walks and `BrowserUrlExtractor`; unrecycled nodes were a steady native-heap leak on the hottest path. All five `rootInActiveWindow` obtain sites (event loop, `countContent`, `handleBrowser`, and `performBackInternal`/`lockScreen` via the `activeWindowProtectedNow()` helper) recycle the root in `try/finally`.
- **Batched usage-time writes** — `ContentCounter` accumulates foreground usage in memory (`pendingUsageMs`) and flushes to prefs at `USAGE_FLUSH_MS` (5 s), on app switch, on protected-app foreground, on every snapshot pull, and on dispose. Previously it wrote SharedPreferences once per accessibility event at scroll frequency. Ceiling: ≤5 s of usage time lost on a hard process kill.
- **Shared day-key formatter** — `engine/DateKeys.kt`: one `ThreadLocal` `"dd-MM-yyyy"` `SimpleDateFormat` (thread-local because the widget provider / job service can run off the main thread), replacing the duplicated per-call allocations (service, `ContentCounter`, `CommandHandler`, widget provider — and the bubble's `dateKey()`, the last `SimpleDateFormat` holdout, now timezone-change correct). `today()` re-applies `TimeZone.getDefault()` on every call — the cached formatter would otherwise freeze the zone captured at first use, and the service process lives long enough for a timezone change (travel / auto-adjust) to roll days over at the old zone's midnight.
- **Config prefs split** — the ~31 KB `platforms_config_json` lives in its own SharedPreferences file `detoxo_platforms_config` (every `.apply()` re-serialises the whole file, and the hot path writes counters into `detoxo_engine_prefs` constantly). `ConfigStore.init` runs an idempotent one-time migration out of the old file.
- **Conscious daily reset** — `accountConscious` checks `ConfigStore.consciousDate` against today and zeroes the bank on day change, so an overnight abstain no longer stockpiles a free 10-minute morning allowance.

### Static handle

`DetoxoAccessibilityService.instance` (volatile, private-set) is the bridge everything else uses: `CommandHandler` reaches the live service through it (`instance?.reload()`, `instance?.contentCounter`, `instance?.consciousSnapshot()`, `instance?.armReelSession()`, `instance?.reelSessionSnapshot()`, etc.). `isRunning()` returns whether `instance != null`. Every call site null-checks, so commands degrade gracefully when the service is disabled.

**One Reel / Unblock runtime state.** The `oneReel` plan (allow N reels, then block — algorithm in [03-detection-engine.md](03-detection-engine.md) §5.3) keeps its dwell state in `@Volatile` runtime fields on the service (`lastScrollAtMs`, `oneReelPage`, `reelViewStartMs`, `reelViewCounted`, `lastReelCountMs`) that are meaningless across a restart, so `armReelSession()` zeroes them, `reload()`s, and emits fresh state. The consumed-count itself lives in `ConfigStore` (`reels_consumed`) and is **persisted**, so an OS-driven service restart keeps the user blocked until an explicit re-tap — the volatile timestamps self-correct from the persisted count. `reelSessionSnapshot()` (`{consumed, allowance, blocked, active}`) mirrors `consciousSnapshot()` and backs both the `reelSessionState` event and its pull query.

Note the service is **never** started manually. An enabled AccessibilityService is bound (and re-bound after reboot) by the OS — and it cannot be rebound programmatically, which is why the boot-time hook only (re)arms the detect-and-notify watchdog rather than trying to restart anything (§5).

---

## 3. CommandHandler (Dart → native)

`channels/CommandHandler.kt` implements `MethodChannel.MethodCallHandler`. It is the single entry point for every Dart-initiated command. It holds a `ConfigStore` and an optional `Activity` (for launching Settings screens), plus a single-thread `ioExecutor` for the potentially-slow calls (`installedPackages`, `installedApps`).

Broadly the methods fall into four groups. (Argument/return shapes are in [18-platform-channel-contracts.md](18-platform-channel-contracts.md).)

**Config / settings push** — write to `ConfigStore`, then `DetoxoAccessibilityService.instance?.reload()`:
`pushConfig`, `pushSettings`, `pushWebBlocklist`, `pushProtectedApps`, `pushAppBlocklist`, `pushRules`.

- `pushConfig` is **fail-safe**: an absent `json` arg or one that fails a `JSONObject` parse is a no-op, never a wipe. (Previously a null arg silently nulled the stored config, which parses to `EMPTY` — killing both blocking and counting until the next good push.)

- `pushSettings` unpacks `activePlan`, `defaultBlockMode`, `enabledPlatforms`, `vibration`, `masterEnabled`, `pauseUntil`, `reelAllowance`, `consciousEarnDivisor`, `consciousMaxBankMs`, `blockAdultWebsites`, `blockWebsitesForBlockedApps`. The `activePlan` is stored **verbatim** — the old auto-reset of the Conscious bank on a `*→CURIOUS` transition was **removed**, so an auto-revert *into* Conscious (after an override that ran from a Conscious base) keeps the earned bank; the fresh-start reset now lives in the separate `resetConsciousBank` command below. `reelAllowance` is stored as the target (survives restart) but the One Reel / Unblock **consumed-count is not reset here** — only the imperative `armReelSession` re-arms, so an unrelated push can't refill a spent session.

- `pushProtectedApps` stores the privacy-protected package names as a
  `StringSet` (`protected_packages`) — **set-if-changed**: an absent/malformed
  arg is a no-op (never a wipe), an unchanged set skips the prefs write, and a
  changed set triggers only the cheap `refreshProtectedPackages()` (no full
  config re-parse). The service caches the set in a `@Volatile` field and does
  **nothing at all** while one of those apps is the event source, the tracked
  foreground, or the active window's own package (`activeWindowProtected`, the
  anchor that survives a stale/clobbered `foregroundPkg`) — no counting, no URL
  reads, no tree walks, no blocking; `performBackInternal`/`killApp`/`lockScreen`
  are individually guarded as fail-closed backstops. See
  [24-protected-apps.md](24-protected-apps.md).

- `pushAppBlocklist` stores the custom whole-app-block package names as a
  `StringSet` (`app_blocklist_packages`) with the same fail-safe/set-if-changed
  contract as `pushProtectedApps`: absent/malformed arg = no-op (clearing
  requires an explicit empty list), unchanged set skips the write and the
  cheap `refreshAppBlocklist()` refresh. Enforcement (HOME bounce, own 1200 ms
  debounce, shared block counter, protected/self/launcher/systemui skips) is
  in the service's `onAppBlocked` — see
  [06-app-and-web-blocker.md](06-app-and-web-blocker.md).

- `pushRules` stores the **resolved rules snapshot** (`rules_json`, a JSON
  array — schedules already turned into absolute windows, spent daily limits,
  the daily reel limit's meter) with `pushWebBlocklist`'s fail-safe contract
  (absent / non-array = no-op, unchanged = no prefs rewrite), always writes
  `next_boundary_ms`, then the cheap `refreshRules()` re-reads both into
  `RuleEngine` and the service's boundary mirror. Enforcement (the package arm
  below the Pause gate, the host arm in `handleBrowser`, the platform arm in the
  detector loop, `ruleBoundary`) is in [27-rules-engine.md](27-rules-engine.md).
- `pushTemporaryUnblocks` stores M8's active per-target grants
  (`temporary_unblocks_json`) with the same fail-safe contract, then the cheap
  `refreshTemporaryUnblocks()` re-reads them into the Android-free
  `UnblockRegistry` — which is also called from `reload()`, so a reboot
  re-anchors every grant's **monotonic** deadline against its surviving wall
  stamp. `takePendingUnblock` reads **and clears** the target of an "Unblock for
  a while" tap on the wall. Both in
  [31-locked-rules-and-unblock.md](31-locked-rules-and-unblock.md).

**Permission queries & launches** — pure platform checks and Settings intents:
`isAccessibilityEnabled`, `openAccessibilitySettings`, `canDrawOverlays`, `requestOverlayPermission`, `hasUsageAccess`, `openUsageAccessSettings`, `isIgnoringBatteryOptimizations`, `requestIgnoreBatteryOptimizations`, `isDeviceAdminActive`, `requestDeviceAdmin`, `removeDeviceAdmin`.

- `isAccessibilityEnabled` delegates to the shared **`engine/AccessibilityCheck.kt`** (also used by the watchdog): it reads `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES` and matches our `ComponentName` case-insensitively in **both** flattened forms — long (`pkg/pkg.Class`) and short (`pkg/.Class`), since some OEM ROMs write the short one. It does **not** rely on the service's `instance`, so it is correct even before first bind. A false negative here would push an already-granted user into the restricted-settings recovery flow, hence accepting both. Note this is the *setting*, not liveness — `serviceAlive` (`instance != null`) is the truth for "running".
- `hasUsageAccess` uses `AppOpsManager` (`OPSTR_GET_USAGE_STATS`), API-versioned (`unsafeCheckOpNoThrow` on Q+).
- Device-admin add/remove go through `DevicePolicyManager` against `DetoxoDeviceAdminReceiver` (§6).
- `launch(intent)` prefers the held `Activity`; with none it adds `FLAG_ACTIVITY_NEW_TASK` and starts from the app context. All launches are wrapped in try/catch and return a boolean.

**Direct block actions & stats** — forwarded to the live service:
`performBack`, `killApp` (needs a `package`), `lockScreen`, `consciousState`, `resetConsciousBank`, `armReelSession`, `reelSessionState`, `blockStats`.

- `consciousState` returns the live `instance?.consciousSnapshot()`, else a store-derived fallback map so the UI still gets a sensible value when the service is dead.
- `resetConsciousBank` empties the Conscious earn-bank: `store.resetConsciousBank()` (no-arg — zeroes **only the bank**; the tick anchor is runtime-only now), then the service hook `instance?.onConsciousBankReset()` drops the cached bank *and* any pending unflushed accrual (so it can't resurrect the zeroed value) and `reload()`s. It is the **only** bank-reset path (the old `pushSettings` plan-transition reset is gone), fired only by Dart's `SettingsCubit.enterConscious()` on a genuine user entry — so an auto-revert into Conscious keeps the bank. The service's own `accountConscious` accountant also **freezes** the bank during a live Pause (`now < pauseUntil`), mirroring its master-off freeze, so a paused Conscious base doesn't accrue free allowance ([03](03-detection-engine.md) §5.2).
- `armReelSession` ((re)arm One Reel / Unblock): reads `count` (clamped 1..20), sets `store.reelAllowance` + `activePlan = "ONE_REEL"`, calls `store.resetReelSession()` (consumed→0), then `instance?.armReelSession()`. Imperative so an unrelated `pushSettings` never re-arms mid-session.
- `reelSessionState` returns the live `instance?.reelSessionSnapshot()`, else a store-derived fallback (`consumed`/`allowance` from prefs, `blocked = consumed >= allowance` AND-ed with plan `ONE_REEL`).
- `blockStats` reads `store.blockStats(DateKeys.today())` — `ConfigStore.blockStats(dateKey)` (like its `webBlockStats(dateKey)` twin) does **read-time day rollover**: a stale stored date reads `today` as 0 without writing (the next `recordBlock` does the durable reset), mirroring `ContentCounterStore.snapshot`. So a post-midnight pull no longer reports yesterday's count.
- `monotonicNow` returns `{elapsedMs: SystemClock.elapsedRealtime(), bootCount: Settings.Global.BOOT_COUNT}` — monotonic clocks immune to Settings changes, with the boot count making cross-boot readings detectable. They anchor the PIN lockout (EVO-015) so moving the clock forward can't clear it ([08](08-pin-lock-recovery.md)); the PIN-lock siblings `setSecureScreen` / `lastScreenOff` are in [18](18-platform-channel-contracts.md).

**Content counter & widget** — see §7/§8:
`contentCounterSnapshot`, `setContentCounterEnabled`, `setContentBubbleEnabled`, `refreshContentWidget`, `setCounterStyle`, `pinContentWidget`.

**Device / package info**:
`deviceInfo` (brand/manufacturer/model/sdkInt); `installedPackages` runs `queryLaunchablePackages()` on the `ioExecutor` and posts the result back on the platform thread (Flutter requires the reply on the main thread). It enumerates `MAIN`/`LAUNCHER` activities and de-dups by package, returning **`null` (not empty)** on failure so Dart treats install-state as "unknown" and keeps showing the full blocklist rather than hiding every app.

`installedApps` is the picker-grade sibling (drives the add-app picker in App Blocker and Protected apps): the same `resolveLaunchables()` walk (shared helper), plus per-app `loadLabel` and `rasterizeIcon(loadIcon())` — any `Drawable` (adaptive/vector/bitmap) drawn straight into a 96×96 `ARGB_8888` bitmap and PNG-compressed, so drawing at target bounds *is* the downscale. Detoxo's own package is skipped, each icon load has its own try/catch (`icon: null` on failure, never a dead list), and the whole command runs on the same `ioExecutor`. Same `null`-on-total-failure contract as `installedPackages`.

The Conscious plan token is `PLAN_CONSCIOUS = "CURIOUS"` — the internal/wire value is `CURIOUS`; its user-facing label is **"Conscious"**. Do not rename the token. The One Reel / Unblock token is `PLAN_ONE_REEL = "ONE_REEL"`.

Any unrecognized method returns `result.notImplemented()`.

---

## 4. ServiceEventBus & the in-process event bridge

Native → Dart events use two small classes:

- **`engine/ServiceEventBus.kt`** — a singleton `object` with a `@Volatile var sink: Sink?`. The service calls `ServiceEventBus.post(type, data)`, which merges `data` with `{"type": type}` and delivers it to the sink **on the main thread** (`Handler(Looper.getMainLooper())`). If no sink is registered (UI dead / not listening), the event is silently dropped — the block hot-path never depends on it. **Exception: `serviceStatus` is sticky** — the last payload is recorded even with no sink, and `replayLastStatus()` re-emits it to the current sink. A cold start races the service rebind: `onServiceConnected`'s `running:true` fires before Dart attaches the EventChannel and would otherwise be lost, leaving the dashboard on "Protection off" for the whole session.
- **`channels/DetoxoEventStream.kt`** — the `EventChannel.StreamHandler`. `onListen` installs a sink that forwards to `events.success(...)` and then calls `replayLastStatus()` to catch the late subscriber up. `onCancel` clears the sink **only if it is the one this instance installed** — Flutter engine recreation can run the new engine's `onListen` before the old engine's `onCancel`, and an unconditional clear nulled the live listener's sink. So the bus is "connected" only while Dart is actively listening on `com.errorxperts.detoxo/events`. (Dart's side is symmetric: `EngineChannel.events()` is a self-healing broadcast stream that re-subscribes 1 s after the underlying channel stream closes, so cubits' process-lifetime subscriptions survive a native stream close.)

Event `type` values emitted by the native layer: `serviceStatus`, `blocked`, `webBlocked`, `consciousState`, `reelSessionState`, `contentCounted`. Payload shapes are in [18](18-platform-channel-contracts.md). The events are multiplexed onto the single channel and demultiplexed on the Dart side by the `type` field.

---

## 5. BootReceiver + WatchdogJobService (protection watchdog)

`receivers/BootReceiver.kt` is a `BroadcastReceiver` registered in the manifest for `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, and `QUICKBOOT_POWERON`. Its `onReceive` logs the action and **(re)schedules the watchdog job** (`WatchdogJobService.schedule`).

`exported="true"` is required for `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` (both **protected** broadcasts only the system can send). `QUICKBOOT_POWERON`, however, is an **unprotected OEM action any app may send** — so the receiver's payload must stay an idempotent, harmless re-schedule; never add state changes to `BootReceiver`. (The manifest comment documents the same invariant.)

It intentionally does **not** restart the service. An enabled AccessibilityService is re-bound automatically by the OS after boot/update — and **cannot be rebound programmatically**, so after an OEM force-stop only the user can re-enable it. Detect + notify is therefore the ceiling (this matches EVO-013's Realme/ColorOS finding), and that is what the watchdog does. There is no date-changed receiver and no custom command broadcast — all commands arrive over the MethodChannel.

`receivers/WatchdogJobService.kt` — a persisted periodic `JobScheduler` job.
Besides the liveness check, each run pushes the home-screen counter widget from
the store (`ContentCounterWidgetProvider.pushUpdate`, a no-op when nothing is
pinned) — the widget only re-renders on a count, so this is what turns its
"today" over after midnight ([17](17-content-counter.md) §5.2) — and does two
rules jobs ([27](27-rules-engine.md)): `checkRuleBoundary` posts `ruleBoundary`
once a pushed window edge has passed, and **`reconcileLimits`** re-measures every
PENDING rule budget against `UsageQuery` and flips the ones that are used up, so a
daily limit starts enforcing without Detoxo being opened. Both are gated (a live
service, a pending budget, the Usage Access grant) and wrapped in their own
try/catch; neither adds a job, an alarm or a permission:

| Constant | Value |
|---|---|
| `JOB_ID` | `1126` |
| Period | 15 min (`setPeriodic`, `setPersisted(true)` — survives reboot via `RECEIVE_BOOT_COMPLETED`) |
| `NOTIF_ID` | `1127` |
| Channel | `detoxo_watchdog_channel` — **"Protection alerts"**, `IMPORTANCE_DEFAULT` |
| Re-notify debounce | once per 6 h (`ConfigStore.lastWatchdogNotifiedMs`) |

`checkAndNotify` (all synchronous, runs in the app's single process so the live service `instance` is directly visible):

1. `!store.masterEnabled` → return (the user turned protection off themselves).
2. `DetoxoAccessibilityService.instance != null` → **recovery**: `clearAlert` cancels any standing notification and zeroes `lastWatchdogNotifiedMs` (so a stale "Protection stopped" never outlives the outage, and a NEW outage isn't silently swallowed by the old debounce), then return. `onServiceConnected` calls the same `clearAlert` so recovery clears immediately rather than at the next 15-min check.
3. Neither `AccessibilityCheck.isEnabled` nor `store.serviceEverConnected` → return (only nag someone who actually had protection — the setting still lists the dead service after a force-stop, or it connected at least once before the OS/OEM cleared the setting).
4. Within the 6 h debounce → return; else record the time and post the notification: **"Protection stopped"** / "Detoxo is no longer blocking. Tap to re-enable it.", auto-cancel, deep-linking to `ACTION_ACCESSIBILITY_SETTINGS` (exactly where the re-toggle happens). Channel name/description and title/text come from `res/values/strings.xml` (`watchdog_channel_name` / `watchdog_channel_description` / `watchdog_title` / `watchdog_text`).

Scheduling is idempotent (a still-pending `JOB_ID` is left alone) and armed from two places: the service's own `onServiceConnected` and `BootReceiver`. Everything is try/caught — a missing `POST_NOTIFICATIONS` grant must never crash the job.

The tick also runs `checkRuleBoundary` ([27](27-rules-engine.md) §5–6): when the pushed
`next_boundary_ms` has passed it posts `ruleBoundary` once and zeroes the key — through the live
service instance when there is one (it holds the in-memory mirror), else straight from
`ConfigStore`. Dropped when no Dart listener is attached; the next resume re-pushes anyway. No new
job, no alarm — the watchdog stays the engine's only periodic job.

---

## 6. DeviceAdminReceiver + policies (uninstall protection)

`admin/DetoxoDeviceAdminReceiver.kt` extends `DeviceAdminReceiver`; its `onEnabled`/`onDisabled` only log. Enabling it as an active device admin buys two things:

1. **Uninstall protection** — the app cannot be removed while the admin is active.
2. **`lockNow()`** — enables the `LOCK_SCREEN` block mode. The service's `lockScreen()` checks `dpm.isAdminActive(...)` before calling `dpm.lockNow()`, so the lock mode is a no-op unless admin is granted.

Policy set (`res/xml/device_admin_policies.xml`) is deliberately minimal:

```xml
<device-admin>
    <uses-policies>
        <force-lock/>
        <watch-login/>
    </uses-policies>
</device-admin>
```

Manifest declaration: `exported="true"`, guarded by `android.permission.BIND_DEVICE_ADMIN`, `<meta-data android:name="android.app.device_admin">` → the policies XML, and an `intent-filter` for `DEVICE_ADMIN_ENABLED`. The admin's user-facing strings come from `strings.xml` (`device_admin_label` "Detoxo Uninstall Protection", `device_admin_description`).

Admin is opt-in and reversible: `CommandHandler.requestDeviceAdmin()` fires `ACTION_ADD_DEVICE_ADMIN` (with an explanation extra); `removeDeviceAdmin()` calls `dpm.removeActiveAdmin(...)`.

---

## 7. ContentCounterBubble (overlay)

`overlay/ContentCounterBubble.kt` is the floating "reels seen today" badge. It runs **inside the existing accessibility FGS** — no new service — and all view operations run on the main `Looper` (`runOnMain`). Counting and blocking are decoupled: the bubble is driven by `ContentCounter`, not the block path.

Beyond counting reels, the counter also accrues **whole-app foreground time** in monitored apps: `countContent` calls `contentCounter.onAppActivity(pkg)`, which sums the gap between consecutive events from the same monitored app (only when under `USAGE_ACTIVE_GAP_MS = 12000ms`) into `cc_time_today` / `cc_time_total`. This adds **no new permission** (it reuses the AccessibilityService) and feeds the dashboard screen-time ring and the bubble's tap-to-reveal-time. Algorithm detail: [03-detection-engine.md](03-detection-engine.md) §6 and [17-content-counter.md](17-content-counter.md) §2.6.

### Window

- `WindowManager` overlay. Type is `TYPE_APPLICATION_OVERLAY` on API 26+, falling back to the deprecated `TYPE_PHONE` below that (`overlayType()`).
- Flags: `FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL | FLAG_LAYOUT_NO_LIMITS`, `TRANSLUCENT`, gravity `TOP|START`.
- **Steady-state fast path first** — `show()` checks `shown && view != null && view.isAttachedToWindow` *before* the `Settings.canDrawOverlays` binder call, so the per-detection IPC is gone while the window is alive. The `isAttachedToWindow` requirement is what makes an overlay **revoke → re-grant** recover: the OS removes the window on revoke but the fields survive, and without the check a later re-grant would keep updating a detached view forever. A detached-but-tracked view is torn down via the private `detach()` (shared with `hide()`) before re-adding.
- **No-ops without overlay permission** — past the fast path, `show()` returns early if `!Settings.canDrawOverlays(context)`, with a **once-per-process `Log.w`** ("bubble suppressed: overlay permission missing") so a revoked grant doesn't read as "the counter stopped" with zero trace (counting itself keeps running). `addView`/`updateViewLayout`/`removeView` are all try/caught so a revoked permission or a race can't crash the service.
- **Day key via `DateKeys.today()`** — the bubble's `dateKey()` uses the shared engine formatter (its private `SimpleDateFormat` was the last holdout; the shared one re-applies the default timezone per call, so a timezone change rolls the day correctly).

### Interaction

- **Tap** (resolved by a `GestureDetector` alongside the drag handler, gated on the `showTime` style flag, default on):
  - `showTime` **on** → **single tap** briefly (`REVEAL_MS = 3000ms`) reveals today's watch time (`store.timeTodayMs`) on the bubble, then reverts to the count; **double tap** launches the app.
  - `showTime` **off** → **single tap** launches the app (legacy behavior).
  - Launch uses `getLaunchIntentForPackage` with `NEW_TASK|SINGLE_TOP`; a drag past slop suppresses the tap.
- **Drag** → moves the window; on release it **springs to the nearest horizontal edge** (`snapToEdge`, `ValueAnimator` + `DecelerateInterpolator`) and persists the position.
- Press feedback (scale down on touch), a spring-in on show (`OvershootInterpolator`), and a pop on each new count (`onCounted`).
- Position is **clamped on-screen** (`clampY`, `restorePosition`) and persisted across shows/restarts via `ContentCounterStore.bubbleX/bubbleY` (px; `-1` = unset → default edge).

### Appearance

`BubbleStyleSpec.fromJson(store.bubbleStyleJson)` parses the Dart-pushed style JSON (persisted via the `setCounterStyle` command) and **re-clamps every field** so a malformed payload can never produce an unusable bubble. Four variants, rendered by the inner `BubbleView` on a software layer (redraws only on count change):

| Variant | Face |
|---|---|
| `GLASS_ORB` (default) | dark glass circle, seed→accent gradient ring, mint glow, centered count |
| `USAGE_RING` | glass disc + usage-colored progress arc (`UsageLadder`, capped) |
| `EMOJI_MOOD` | mood emoji (worsens per 50 reels) over a small count |
| `MINIMAL_PILL` | compact capsule: count + usage-colored dot, width wraps the digits |

Colors/emoji come from `engine/UsageLadder.kt` (shared with the widget and the Flutter previews). `onStyleChanged()` rebuilds the view in place at the same position when a style is pushed while the bubble is shown.

Above the four variants sits a **"reels left" override**: `setRemaining(Int?)` (fed by `ContentCounter.setReelSessionRemaining`, which the AccessibilityService's `syncReelBubble()` drives on arm/allow/revert) makes `BubbleView` draw a distinct teal unlock badge with the remaining One Reel / Unblock count instead of any styled variant, reverting to the today-total when the session ends. Display-only — counting is unaffected. Detail in [17-content-counter.md](17-content-counter.md) §5.1.

`overlayType()` and the "open Detoxo" launch intent are shared with the block screen through `overlay/OverlayWindows.kt`.

### 7b. BlockScreenOverlay (the intervention wall)

The second overlay in the package: `overlay/BlockScreenOverlay.kt` is an `object` holding one full-screen `TYPE_APPLICATION_OVERLAY` window (flags 808, drawn under the system bars and into the cutout) plus two edge strips that swallow the back gesture, raised by the accessibility service at app and website blocks, at reel blocks in the **Block screen** mode or when forced (`overlay/WallPolicy.kt` — a spent daily limit, a schedule, a drained Conscious bank), and by `CommandHandler`'s preview arm. It is fail-safe (no grant → `false` → the trigger site keeps its toast), always dismissible from an on-screen action, and comes down on a foreground change away from the app it covers, on Pause / protection-off (`reload()`), on screen-off (a `BroadcastReceiver` registered on the **service** in `onServiceConnected`, unregistered inside `runCatching` from `onUnbind` and `onDestroy` — the MainActivity receiver is dead whenever the UI is), and when the service unbinds. The face is Canvas-drawn with real `Button`s underneath so TalkBack gets one target per action. Everything else — trigger sites, hide rules, renderer, style + on/off switch, channel — is in [25-block-screen.md](25-block-screen.md).

### 7c. NudgeOverlay (the soft nudge card)

The third overlay: `overlay/NudgeOverlay.kt` is an `object` holding one small **bottom-anchored** window — 88 % width, `WRAP_CONTENT`, `Gravity.BOTTOM or CENTER_HORIZONTAL` 96 dp up — raised by the accessibility service when the dwell machine crosses a threshold, and gone six seconds later on its own `Handler`. It is the deliberate inverse of the wall: `FLAG_NOT_TOUCH_MODAL` with no `MATCH_PARENT` view and no gesture strips, so every touch outside the card passes straight through and the user keeps scrolling. Fail-safe the same way (no grant → `false` → the service reports nothing and re-arms), and it shares `overlayType()` plus the `canDrawOverlays` recheck-throttle and teardown patterns with the other two. The two overlays never coexist: the nudge short-circuits on `BlockScreenOverlay.isShowing()`, and `tearDownOverlays()` / the screen-off receiver take both down together. Everything else — the dwell machine, its call site, config, channel — is in [30-soft-nudge.md](30-soft-nudge.md).

---

## 8. ContentCounterWidgetProvider (home-screen widget)

`widget/ContentCounterWidgetProvider.kt` is an `AppWidgetProvider` for a **2×2** home-screen widget showing today's reel count + all-time total.

- **Single source of truth**: `ContentCounterStore` (`detoxo_engine_prefs`). The widget reads `snapshot(dateKey())` directly, so it is correct even when the Flutter UI is dead. Persisted counts live under keys `cc_today` / `cc_total` (per-app maps under `cc_per_app_today` / `cc_per_app_total`).
- **Live updates are pushed natively**: `updatePeriodMillis=0` (no polling). The native counting brain calls `ContentCounterWidgetProvider.pushUpdate(context, snapshot)` on each counted reel (throttled) and on style changes; `pushUpdate` is a cheap no-op when no instances are pinned.
- **Bitmap-rendered face**: the widget draws to a `Bitmap` via `WidgetBitmapRenderer` (honouring the user's chosen glass background/theme/density and the persisted `widgetStyle` JSON) and sets it into `RemoteViews`. It re-renders on `onAppWidgetOptionsChanged` (resize) at the launcher-reported size, clamped to bound bitmap memory.
- **Tap** → launches the app via a `PendingIntent` (`FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE`).
- **Pin request**: `CommandHandler.pinContentWidget()` calls `AppWidgetManager.requestPinAppWidget(...)` (API 26+, guarded by `isRequestPinAppWidgetSupported`).

Provider metadata (`res/xml/content_counter_widget_info.xml`): `minWidth/minHeight 110dp`, `targetCell 2×2`, `updatePeriodMillis=0`, `resizeMode horizontal|vertical`, `widgetCategory home_screen`, initial + preview layouts. This is the **only** widget surface: Dart pins and refreshes it through the `pinContentWidget` / `refreshContentWidget` commands, the render and all reads are done here in Kotlin, and the 15-min watchdog job re-pushes it so "today" rolls over after midnight (§5).

---

## 9. Manifest

`android/app/src/main/AndroidManifest.xml`.

### Permissions

| Permission | Purpose |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | networking (config swap-in; currently offline-first) |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE` | the accessibility FGS |
| `SYSTEM_ALERT_WINDOW` | the overlay bubble (and any block overlays) |
| `POST_NOTIFICATIONS` | the ongoing FGS notification |
| `RECEIVE_BOOT_COMPLETED` | `BootReceiver` |
| `PACKAGE_USAGE_STATS` | usage-access permission surface |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | battery-exemption request |
| `KILL_BACKGROUND_PROCESSES` | the `KILL_APP` block mode |
| `VIBRATE` | block haptics |
| `USE_BIOMETRIC` | PIN/biometric app lock (`local_auth`) |
| `WAKE_LOCK` | reliability of the service |

**Deliberately absent** (see [22-play-release.md](22-play-release.md) §1):

| Permission | Why not |
|---|---|
| `QUERY_ALL_PACKAGES` | `queryLaunchablePackages()` only calls `queryIntentActivities(MAIN + LAUNCHER)`, already covered by `<queries>`. Declaring a Play-restricted permission for no functional gain invites a Console declaration and a review question. |
| `com.android.vending.BILLING` | no live billing; the SDK was removed |
| `com.google.android.gms.permission.AD_ID`, `ACCESS_ADSERVICES_*` | **merged in by Firebase Analytics**, so they are stripped with `tools:node="remove"`. Analytics works without the advertising ID, and this keeps the data-safety form consistent with the in-app "no ad tracking" claim. Re-verify the merged manifest after any Firebase bump. |

### Application components

- **`.MainActivity`** — `FlutterFragmentActivity`, `singleTop`, `taskAffinity=""`, exported launcher activity. `enableOnBackInvokedCallback="true"` on `<application>`.
- **`.accessibility.DetoxoAccessibilityService`** — `exported="false"`, permission `BIND_ACCESSIBILITY_SERVICE`, `foregroundServiceType="specialUse"` with the required `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` property string, an `AccessibilityService` intent-filter, and `<meta-data android:name="android.accessibilityservice">` → `@xml/accessibility_service_config`. No `android:process` → **main process**.
- **`.receivers.BootReceiver`** — exported (required for the protected `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` broadcasts; `QUICKBOOT_POWERON` is an unprotected OEM action, so the payload must stay an idempotent re-schedule — §5).
- **`.receivers.WatchdogJobService`** — `exported="false"`, permission `BIND_JOB_SERVICE` (the protection watchdog, §5).
- **`.notifications.DetoxoNotificationListener`** — `exported="false"`, permission `BIND_NOTIFICATION_LISTENER_SERVICE`, a `NotificationListenerService` intent-filter, `android:label="@string/notification_listener_label"`. **No `<uses-permission>`**: the `BIND_` guard is declared on the tag and held by the system. Cancels notifications from apps blocked right now, and is bound only while the user's toggle is on — see [29](29-notification-suppression.md).
- **`.widget.ContentCounterWidgetProvider`** — `exported="false"`, `APPWIDGET_UPDATE` filter, `<meta-data>` → `@xml/content_counter_widget_info`.
- **`.admin.DetoxoDeviceAdminReceiver`** — exported, `BIND_DEVICE_ADMIN`, `<meta-data>` → `@xml/device_admin_policies`, `DEVICE_ADMIN_ENABLED` filter.

### `<queries>` (package visibility, Android 11+)

- `PROCESS_TEXT` (`text/plain`) and `MAIN` — general app visibility; the `MAIN` entry is what lets `installedPackages` enumerate launchable apps. This is now the *only* mechanism: `QUERY_ALL_PACKAGES` was removed.
- `VIEW` with `https` and `http` schemes — browser visibility for the website blocker.

---

## 10. res/xml configs

### `accessibility_service_config.xml`

| Attribute | Value |
|---|---|
| `accessibilityEventTypes` | `typeWindowStateChanged \| typeWindowContentChanged \| typeViewScrolled` — exactly the three types the engine acts on (EVO-016; was `typeAllMask`, which binder-delivered every other type only to discard it at the handler's first lines). Device QA still outstanding — see `docs/evolution/proposals/EVO-016-event-mask-narrowing.md`. |
| `accessibilityFeedbackType` | `feedbackGeneric` |
| `accessibilityFlags` | `flagDefault \| flagRetrieveInteractiveWindows \| flagReportViewIds \| flagIncludeNotImportantViews` |
| `canRetrieveWindowContent` | `true` (read node trees) |
| `canPerformGestures` | `true` (global-action back / future gesture blocks) |
| `notificationTimeout` | `100` ms |
| `description` / `summary` | `@string/accessibility_service_description` / `@string/accessibility_service_summary` |

`flagRetrieveInteractiveWindows` + `flagReportViewIds` are what make the 3-stage view-id detection ([03](03-detection-engine.md)) possible — reading the foreground app's view tree and resource-ids.

**No key-event filtering**: `flagRequestFilterKeyEvents` / `canRequestFilterKeyEvents` were dropped — there is no `onKeyEvent` override, and requesting the capability both scares the Play reviewer and costs key-event delivery overhead for nothing.

### `device_admin_policies.xml`

`force-lock` + `watch-login` only (see §6).

### `content_counter_widget_info.xml`

See §8.

### `strings.xml`

`app_name` (Detoxo), the accessibility description/summary, `device_admin_label`/`device_admin_description`, `cc_widget_description` ("Reel counter") — plus the **engine surfaces**: `toast_blocked` (`"%1$s is blocked by Detoxo"`, one shared string for both web and whole-app block toasts so the copy can never drift apart), `toast_blocked_adult` (`"Adult site blocked by Detoxo"` — adult-list hits are never named on screen, EVO-018), the FGS notification strings (`fgs_*`) and the watchdog notification strings (`watchdog_*`).

---

## 11. Build config

`android/app/build.gradle.kts`:

- `namespace` / `applicationId` = `com.errorxperts.detoxo`.
- `minSdk = 24` (AccessibilityService + overlays + the plugin set are comfortable here; the `specialUse` FGS type is gated at API 34 in code). `compileSdk` / `targetSdk` / version fields come from the Flutter Gradle plugin.
- Java 17, Kotlin `jvmTarget = 17`, `multiDexEnabled = true`, **core library desugaring** (`desugar_jdk_libs 2.1.4`, required by `flutter_local_notifications`).
- `release` signing loads `android/key.properties` (gitignored). The config is registered **only when that file exists** — an unguarded `as String` cast used to fail *configuration* for every build type on a fresh clone or CI machine. When it is missing the release type falls back to debug signing and logs a warning, so local release builds still run; `bash tool/dev.sh release` refuses to produce an unsigned upload artifact. See [22-play-release.md](22-play-release.md) §2.
- `release` also sets `isMinifyEnabled` / `isShrinkResources` with `proguard-rules.pro` on top of `proguard-android-optimize.txt`.

---

## Related docs

- [03-detection-engine.md](03-detection-engine.md) — detection algorithm, block modes, Conscious/Pause internals, `ConfigStore`, `ContentCounter`, `WebBlockEngine`.
- [18-platform-channel-contracts.md](18-platform-channel-contracts.md) — the full command/event wire contract and the Dart wrappers.
- End-user overviews: [../info_docs/](../info_docs/).

---

## Source files

- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/res/xml/accessibility_service_config.xml`
- `android/app/src/main/res/xml/device_admin_policies.xml`
- `android/app/src/main/res/xml/content_counter_widget_info.xml`
- `android/app/src/main/res/values/strings.xml`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/MainActivity.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/DetoxoEventStream.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ServiceEventBus.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounterStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ReelTracker.kt` (counting rule; `settledPage` shared with the One Reel gate)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NudgeTracker.kt` (soft-nudge dwell machine, Android-free — [30](30-soft-nudge.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DateKeys.kt` (shared ThreadLocal day-key formatter)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/AccessibilityCheck.kt` (shared enabled-in-Settings check)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NodeRecycling.kt` (`recycleSafe` extension)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/BootReceiver.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/WatchdogJobService.kt` (protection watchdog)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/admin/DetoxoDeviceAdminReceiver.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/ContentCounterBubble.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/OverlayWindows.kt` (shared `overlayType` / `launchDetoxo`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenOverlay.kt`, `BlockScreenRenderer.kt`, `WallPolicy.kt` (the intervention wall and when it is raised — [25](25-block-screen.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/NudgeOverlay.kt` (the soft-nudge card — [30](30-soft-nudge.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/UsageQuery.kt` (pull-only `UsageStatsManager` reads — [26](26-catalog-and-usage-signal.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/RuleEngine.kt` (the pushed rules snapshot — [27](27-rules-engine.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/LimitReconciler.kt` (the watchdog's rule-budget flip — [27](27-rules-engine.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/widget/ContentCounterWidgetProvider.kt`
- `android/app/build.gradle.kts`
