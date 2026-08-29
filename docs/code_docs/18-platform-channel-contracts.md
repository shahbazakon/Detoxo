# Platform Channel Contracts

The Dart app and the native Android engine communicate over exactly **two Flutter
platform channels** — the home-screen widget included (pinned and refreshed by
two commands below; the former `home_widget` plugin bridge is gone). This doc is
the complete, source-derived contract: every command method (args + return) on
the MethodChannel and every event `type` + payload shape on the EventChannel.

Channel names are defined once in `lib/core/constants/channel_constants.dart` and
mirrored in the native `MainActivity`:

| Direction | Kind | Name |
|---|---|---|
| Dart → native | `MethodChannel` | `com.errorxperts.detoxo/commands` |
| native → Dart | `EventChannel` | `com.errorxperts.detoxo/events` |

Both are wired in `android/.../MainActivity.kt`
(`configureFlutterEngine`): the command channel routes to `CommandHandler`, the
event channel to `DetoxoEventStream`.

---

## Wiring & platform gating (Dart side)

`lib/core/platform_channels/engine_channel.dart` (`EngineChannel`) is the only
low-level wrapper; repositories build on it and it owns no domain logic.

Two hard guarantees baked into the wrapper:

- **Off-Android = no-op.** `PlatformCapabilities.supportsBlockingEngine`
  (`lib/core/platform/platform_capabilities.dart`) gates everything. When false
  (iOS / tests):
  - `events()` returns `const Stream.empty()` — it never subscribes, so no
    per-launch `MissingPluginException` is logged.
  - Every command short-circuits **before** the channel round-trip, returning the
    method's safe default.
- **Errors degrade to defaults.** `_invoke<T>` catches `PlatformException` (logged
  via `AppLogger.e`) and `MissingPluginException`, returning `null` in both cases.

Return coercion helpers (define the default a failed/absent call yields):

| Helper | On success | On null/error |
|---|---|---|
| `invokeBool` | the `bool` | `false` |
| `invokeBoolOrNull` | the `bool` | `null` — **tri-state**: null means "the call didn't answer" (channel error / no native side), *not* "the OS said no". Permission checks use this so one flaky read can't masquerade as a revoked grant ([13](13-onboarding-permissions.md) §3.2) |
| `invokeVoid` | — | — (fire-and-forget) |
| `invokeMap`  | `Map<String,dynamic>` | `{}` (empty map) |
| raw `_invoke<List>` (installedPackages) | the list | `null` |

Native results are always delivered via `result.success(...)`; the only
`notImplemented()` path is the `else` branch of `CommandHandler.onMethodCall` (see
[Declared-but-unhandled methods](#declared-but-unhandled-methods)).

---

## Command channel — `com.errorxperts.detoxo/commands`

Method-name constants live in `ChannelMethods` (Dart) and are matched by string in
`CommandHandler.onMethodCall` (Kotlin). Args are read via
`call.argument<T>("key")`.

### Config / settings push

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `pushConfig` | `{json: String}` | fail-safe: a null arg or one failing a `JSONObject` parse is a **no-op** (never a config wipe — a nulled config parses to `EMPTY` and kills blocking *and* counting), else `store.platformsConfigJson = json`; `service.reload()` | `true` | `pushConfig(String json)` |
| `pushSettings` | settings map (see below) | applies each present key to `ConfigStore`; `service.reload()` | `true` | `pushSettings(Map settings)` |
| `pushWebBlocklist` | `{json: String}` | fail-safe like `pushProtectedApps`: null / non-JSON-array arg is a **no-op** (never a wipe; clearing needs an explicit `"[]"`), an **unchanged** payload (every Web Blocker screen entry re-pushes) skips everything, else `store.webBlocklistJson = json` + `service.refreshWebBlocklist()` (rule set only — no config re-parse) | `true` | `pushWebBlocklist(String json)` |
| `pushProtectedApps` | `{packages: List<String>}` | set-if-changed: absent/malformed arg is a **no-op** (never a wipe), unchanged set skips everything, changed set → `store.protectedPackages` + `service.refreshProtectedPackages()` (no full `reload()`) | `true` | `pushProtectedApps(List<String> packages)` |
| `pushAppBlocklist` | `{packages: List<String>}` | same contract as `pushProtectedApps`: absent/malformed arg = **no-op** (clearing needs an explicit empty list), unchanged set skips everything, changed set → `store.blockedAppPackages` + `service.refreshAppBlocklist()` | `true` | `pushAppBlocklist(List<String> packages)` |
| `pushNudgeConfig` | `{enabled: Bool, packages: List<String>, thresholdStepMs: Long, dailyCap: Int}` | soft nudge ([30](30-soft-nudge.md)). Each field is **independently** fail-safe like `pushProtectedApps` — an absent one leaves the stored value alone. Writes `store.nudge{Enabled,Packages,StepMs,DailyCap}` (the two numbers clamped in the accessor) then `service.refreshNudgeConfig()`, which rebuilds the tracker and hides any standing card when the feature went off | `true` | `pushNudgeConfig({enabled, packages, thresholdStepMs, dailyCap})` |
| `pushRules` | `{json: String, nextBoundaryMs: Long}` | `pushWebBlocklist`'s twin: absent / non-JSON-array `json` = **no-op** (clearing needs an explicit `"[]"`), unchanged `json` skips the prefs rewrite; `nextBoundaryMs` (read as `Number`, clamped to ≥ 0) is **always** written; then `service.refreshRules()` re-reads both into `RuleEngine` + the boundary mirror, re-parsing only on a changed snapshot string | `true` | `pushRules(String json, int nextBoundaryMs)` |
| `pushTemporaryUnblocks` | `{json: String}` | M8's per-target grants — `[{targetType: "REEL" \| "APP" \| "WEBSITE", targetId, endMs}]`, the ACTIVE ones only. The `pushWebBlocklist` arm verbatim: absent / non-array `json` = **no-op** (clearing needs `"[]"`), unchanged skips the prefs write, then `service.refreshTemporaryUnblocks()`. `endMs` is an absolute wall stamp (it has to survive a reboot); `UnblockRegistry` converts it to an `elapsedRealtime` deadline **once per parse**, so moving the system clock back cannot hold a grant open (EVO-048's rule, inherited from the per-site pause this replaces) | `true` | `pushTemporaryUnblocks(String json)` |
| `takeNativeGrants` | — | Reads **and clears** the grants taken on the wall itself (EVO-050), as the `pushTemporaryUnblocks` JSON array. Native has already enforced them; this is how Hive learns about them before its own push would overwrite them ([31](31-locked-rules-and-unblock.md) §5) | `String?` | `takeNativeGrants()` |
| `takePendingUnblock` | — | Reads **and clears** the target of an "Allow for a while" tap on the wall, as `"TYPE\|id"` (stored with a stamp that never crosses the channel; a tap older than 2 min is dropped rather than replayed). A consumable prefs key rather than a replayed event: the tap also foregrounds Detoxo, and on a cold start the EventChannel sink does not exist when `blockScreenAction` is posted ([31](31-locked-rules-and-unblock.md) §5) | `String?` | `takePendingUnblock()` |

**`pushConfig` payload** — `json` is the full `platforms_config.json` string
(featuredApps → platforms → detectors), parsed natively by `DetectionConfig`.

**`pushSettings` payload** — the map is built in
`lib/features/blocking/shared/data/repositories/engine_repository_impl.dart`.
`CommandHandler` reads each key only if present, so partial pushes are legal:

| Key | Type (wire) | Notes |
|---|---|---|
| `activePlan` | `String` | `BlockingPlan.wire`: `BLOCK_ALL` \| `CURIOUS` \| `ONE_REEL` \| `PAUSED`. **`CURIOUS` = the "Conscious" plan** (internal token kept verbatim; UI label is "Conscious"). Stored **verbatim** — `pushSettings` no longer resets the earn-bank on a `*→CURIOUS` transition; the fresh-start reset is the separate `resetConsciousBank` command, so an auto-revert into Conscious keeps the bank. |
| `defaultBlockMode` | `String` | `PRESS_BACK` \| `KILL_APP` \| `LOCK_SCREEN` \| `NONE` |
| `enabledPlatforms` | `List<String>` | stored as a set |
| `vibration` | `bool` | |
| `masterEnabled` | `bool` | engine master switch |
| `pauseUntil` | `Number` (epoch ms, `0` = not paused) | read as `Long` |
| `reelAllowance` | `Number` | read as `Int`; the One Reel / Unblock target (coerced 1..20). Stored as the target only — `pushSettings` does **not** reset the consumed-count (that is the imperative `armReelSession`'s job). |
| `consciousEarnDivisor` | `Number` | read as `Int` |
| `consciousMaxBankMs` | `Number` | read as `Long` |
| `blockAdultWebsites` | `bool` | |
| `blockWebsitesForBlockedApps` | `bool` | |
| `suppressNotifications` | `bool` | Notification suppression on/off. Set-if-changed: on a real change native persists it **and** binds/unbinds the notification listener (`DetoxoNotificationListener.syncBinding`). That is only the responsive half of the "off ⇒ unbound" guarantee — the durable half is `onListenerConnected` re-reading the stored flag, since the OS rebinds on boot regardless ([29](29-notification-suppression.md) §5). Only the switch crosses the channel — the suppressed set is derived natively ([29](29-notification-suppression.md)). |

**`pushWebBlocklist` payload** — `json` is a JSON-encoded array of
`{pattern, matchType}` rules. `matchType` is `WebMatchType.wire`:
`DOMAIN` \| `WILDCARD` (native `WebBlockEngine` matches browser hosts
against these).

> **The plan's one wire-contract change (M8).** This payload used to carry an
> optional per-entry `pausedUntil` (EVO-012/EVO-048). It is **gone**: a paused
> site is now a `WEBSITE` grant on `pushTemporaryUnblocks`, so "this target is
> dormant until T" is one mechanism for reels, apps and websites instead of two
> ([31](31-locked-rules-and-unblock.md) §3). Native ignores the old key for
> free — nothing reads it — so a downgrade cannot resurrect a stale pause, and a
> stored live pause migrates once at bootstrap.

**`pushProtectedApps` payload** — `packages` is a flat list of privacy-protected
package names: the **entire bundled catalog** (always protected, installed or
not) **plus the user's enabled manual additions** — the `protectedPackagesFor`
derivation (see [24-protected-apps.md](24-protected-apps.md)). Deliberately
minimal: app names and categories never cross the channel — native only needs
"is this package protected". Pushed by `ProtectedAppsCubit` on every list change
and by `syncProtectedAppsAtBoot` at splash.

**`pushRules` payload** — `json` is the **resolved rules snapshot**, not the stored
rules ([27](27-rules-engine.md) §5): a JSON array with one entry per rule —
`{id, reason: "SCHEDULE" | "DAILY_LIMIT", mode: "BLOCK" | "ALL_EXCEPT", packages,
domains, platformIds, windows: [[fromMs, untilMs], …], always, reelTimeLimitMs,
strict, usageLimitMs, openLimitCount, spent}`.
Categories are already flattened, windows are absolute epoch-ms resolved 7 days
ahead in the device zone, `always` skips the window check and `reelTimeLimitMs > 0`
is the daily reel limit's native meter. `strict` (EVO-030) makes the entry enforce
**above** the pause gate — and a **locked** rule (M8) is emitted as `strict: true`,
so this snapshot gains **no key** for locking: `locked` / `lockScope` stay
Dart-side, and an active override is expressed by *splitting* that rule's own
`windows` around the lift ([31](31-locked-rules-and-unblock.md) §4). `usageLimitMs` / `openLimitCount` carry the rule's own
daily budget and `spent` says whether it has run out: an entry with a budget and
`spent: false` is **PENDING** — native re-measures it at the watchdog tick
(EVO-029) and never blocks on it until it flips. `nextBoundaryMs` is the earliest
moment any window opens or closes, or an unspent budget is projected to run out
(floored at 60 s), or local midnight when any limit exists; it is pushed even when
no entry is blocking yet, and is clamped to ≥ 0 on the native side.
Built by `syncRules` (`lib/features/limits/rules/domain/rule_sync.dart`) from
persisted state; a failed load aborts the push. `refreshRules()` re-parses only
when the snapshot string actually changed.

**`pushAppBlocklist` payload** — `packages` is a flat list of the **enabled**
custom whole-app-block package names, built by `syncAppBlocklist`
(`lib/features/limits/app_blocker/domain/app_block_sync.dart`) from persisted
state; a failed load aborts the push (native keeps its last-good set). The
service HOME-bounces any event from one of these packages (see
[06-app-and-web-blocker.md](06-app-and-web-blocker.md)). Pushed on every App
Blocker mutation, at splash, and by the resume re-sync heavy leg.

**`pushNudgeConfig` payload** — `packages` is the catalog's `distracting`
behaviour, derived by `nudgePackages()`
(`lib/features/blocking/shared/domain/nudge_sync.dart`) from `Catalog.bundled`,
never curated and never persisted in Dart. **These apps are timed, not blocked**
— it is the one flat package set in the engine that does not mean "intervene".
`thresholdStepMs` is `AppSettings.nudgeThresholdMinutes` in ms. Pushed at splash
and on the resume heavy leg (`syncEngineBlocklists`), and by `SettingsCubit`
after any of the three nudge setters.

### Permission queries & launches

Each `is*/has*/canDrawOverlays` returns a `Boolean`; each `open*/request*` launches
a system settings/consent intent and returns a `Boolean` = *launch succeeded*
(true if `startActivity` didn't throw — **not** whether the user granted it).
The two usage-stats arms are the **only** ones in the handler that `result.error(...)`:
an empty list would be indistinguishable from a quiet day (EVO-014), so a missing
grant reaches Dart as `USAGE_ACCESS_DENIED`, and `EngineChannel.invokeOrThrow` is
the one invoke that lets a `PlatformException` through.
The boolean permission **queries** (`hasUsageAccess`,
`isIgnoringBatteryOptimizations`, `isDeviceAdminActive`) have **no
`EngineChannel` convenience wrapper** — the permission repository reads them
tri-state via `invokeBoolOrNull(method)` directly, so a channel hiccup reads as
`unknown`, never as "revoked" (the old bool-coercing wrappers were deleted as
orphans).

| Method | Args | Returns | Dart wrapper |
|---|---|---|---|
| `isAccessibilityEnabled` | — | `Boolean` (service present in `ENABLED_ACCESSIBILITY_SERVICES`, matched in both long and short flattened `ComponentName` forms) | `isAccessibilityEnabled()` |
| `serviceAlive` | — | `Boolean` (`DetoxoAccessibilityService.instance != null` — the setting can say enabled while the service is dead after an OEM force-stop; EVO-013. `currentStatus()` requires **both** for "running") | `serviceAlive()` |
| `openAccessibilitySettings` | — | `Boolean` | `openAccessibilitySettings()` |
| `canDrawOverlays` | — | `Boolean` (`Settings.canDrawOverlays`) | `canDrawOverlays()` |
| `requestOverlayPermission` | — | `Boolean` | `requestOverlay()` |
| `hasUsageAccess` | — | `Boolean` (`AppOpsManager` GET_USAGE_STATS) | *(none — read tri-state via `invokeBoolOrNull` from the permission repository)* |
| `openUsageAccessSettings` | — | `Boolean` | `openUsageAccess()` |
| `queryAppUsage` | `{startMillis: Long, endMillis: Long}` | `List<{package: String, foregroundMillis: Long}>` (`foregroundMillis > 0` only) — **throws** `PlatformException("BAD_ARGS")` on missing/inverted bounds and `("USAGE_ACCESS_DENIED")` without the grant; `("USAGE_QUERY_FAILED")` if the OS query throws. Off-thread on `ioExecutor`, posted back on the main looper | `queryAppUsage({startMillis, endMillis})` via `invokeOrThrow` — the usage repository maps the errors ([26](26-catalog-and-usage-signal.md)) |
| `queryUsageEvents` | `{startMillis: Long, endMillis: Long}` | `List<{package: String, type: Int, timestampMillis: Long}>`, ascending, `type ∈ {1, 18}` only; same errors as `queryAppUsage` | `queryUsageEvents({startMillis, endMillis})` |
| `isIgnoringBatteryOptimizations` | — | `Boolean` | *(none — read tri-state via `invokeBoolOrNull` from the permission repository)* |
| `requestIgnoreBatteryOptimizations` | — | `Boolean` (launches `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with the package Uri — the one-tap exemption dialog; the manifest holds `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) | `requestIgnoreBattery()` |
| `isDeviceAdminActive` | — | `Boolean` | *(none — read tri-state via `invokeBoolOrNull` from the permission repository)* |
| `requestDeviceAdmin` | — | `Boolean` (launches `ACTION_ADD_DEVICE_ADMIN`) | `requestDeviceAdmin()` |
| `removeDeviceAdmin` | — | `true` (removes active admin; swallows errors) | `removeDeviceAdmin()` |
| `isNotificationListenerEnabled` | — | `Boolean` (`NotificationListenerCheck`: the `enabled_notification_listeners` `Settings.Secure` string, matching both flattened component forms) | *(none — read tri-state via `invokeBoolOrNull` from the permission repository)* |
| `openNotificationListenerSettings` | — | `Boolean` (launches `ACTION_NOTIFICATION_LISTENER_SETTINGS`) | `openNotificationListenerSettings()` |

> **Not on this channel, on purpose.** The restricted-settings / ECM recovery flow
> ([13-onboarding-permissions.md](13-onboarding-permissions.md) §3.4) needs the
> install source and a way to open the app's own settings page. Both already exist
> in dependencies the app ships — `package_info_plus`
> (`PackageInfo.installerStore` → `getInstallSourceInfo().initiatingPackageName`)
> and `permission_handler` (`openAppSettings()` →
> `ACTION_APPLICATION_DETAILS_SETTINGS`). No channel methods were added; don't add
> duplicates.
>
> There is likewise **no method to query the ECM gate itself** — the backing appop
> is `@hide`, read-restricted, and defaults to `MODE_DEFAULT` under ECM, and
> `EnhancedConfirmationManager` is not in the public SDK. Detection is behavioural
> and lives in `PermissionsCubit`.

### Block actions

Direct engine actions, routed to the live `DetoxoAccessibilityService.instance`
(no-op if the service is dead). Used by the PIN / one-reel / test surfaces.

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `performBack` | — | `service.performBackPublic()` | `true` | `performBack()` |
| `killApp` | `{package: String}` | `service.killApp(pkg)` (no-op if pkg null) | `true` | `killApp(String pkg)` |
| `lockScreen` | — | `service.lockScreen()` (device-admin `lockNow`) | `true` | `lockScreen()` |

### Block screen (the intervention wall)

The wall is raised in-process by the service's four trigger sites
([25](25-block-screen.md) §3); these arms exist for the Dart-driven cases (the
style editor's "Try it" preview, the style itself). Unlike the block actions above
they do **not** route through the service instance — `BlockScreenOverlay` is an
`object` that needs only a `Context`, so a preview works with the service dead.

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `showBlockScreen` | the `BlockScreenPayload.toWire()` map (`referenceType`, `referenceId`, `displayName`, `appLabel`, `packageName`, `blockReason`, `plan`, `allowance`, `todayCount`, `allowanceLeft`, `bankMs`, `opensToday`, `offersOpenApp`, `offersUnblock`) | `BlockScreenOverlay.show(context, payload.sanitised(), {ourPackage}, preview = true)` | `Boolean` — `false` when the wall is switched off, the overlay grant is missing, the payload lacks `referenceType`/`blockReason`, or the add failed | `showBlockScreen(Map)` |
| `hideBlockScreen` | — | `BlockScreenOverlay.hide()` | `true` | `hideBlockScreen()` |
| `isBlockScreenShowing` | — | `BlockScreenOverlay.isShowing()` | `Boolean` | `isBlockScreenShowing()` |
| `goHome` | — | `ACTION_MAIN` + `CATEGORY_HOME` + `NEW_TASK` | `true` | `goHome()` |
| `setBlockScreenStyle` | `{style: Map}` (`BlockScreenStyle.toWire()`: `enabled`, `theme`, `background`, `showCount`, `showOpens`, `accentByUsage`, `backDelaySec` 0–60) | persists `ConfigStore.blockScreenStyleJson`, rebuilds a showing wall | `true` (malformed → skipped, still `true`) | `setBlockScreenStyle(Map)` |
| `blockScreenStyle` | — | parses the persisted JSON | the style as a `Map` (`{}` when never saved / malformed) | `blockScreenStyle()` |

### PIN lock / Smart Auto Lock

Activity-scoped commands for the PIN lock's privacy and screen-off features
(see [08-pin-lock-recovery.md](08-pin-lock-recovery.md) §10). These do not touch
the accessibility service.

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `setSecureScreen` | `{enabled: bool}` | add/clear `FLAG_SECURE` on the activity window (hide in Recents + block screenshots); no-op if no activity attached | `true` | `setSecureScreen({required bool enabled})` |
| `lastScreenOff` | — | `MainActivity.lastScreenOffMillis` — wall-clock stamp of the last `ACTION_SCREEN_OFF` this process (0 = never) | `Long` | `lastScreenOff()` → `Future<int>` (0 off-Android) |
| `monotonicNow` | — | The monotonic clocks — immune to Settings clock changes; anchor the PIN lockout (EVO-015). `bootCount` makes a cross-boot reading detectable (`-1` when `BOOT_COUNT` is unreadable) | `Map {elapsedMs: Long, bootCount: Int}` | `monotonicNow()` → `Future<({int elapsedMs, int bootCount})?>` (`null` off-Android / channel error / bootCount < 0 — callers fall back to the wall clock) |

### One Reel / Unblock session control

The `oneReel` plan allows N reels, then re-blocks (semantics in
[05-plans-pause-conscious.md](05-plans-pause-conscious.md) §7). Arming is a **separate
imperative command** — not a `pushSettings` field — so an unrelated settings push can
never re-arm a spent session.

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `armReelSession` | `{count: Int}` (clamped 1..20) | `store.reelAllowance = count`; `store.activePlan = "ONE_REEL"`; `store.resetReelSession()` (consumed→0); `service.armReelSession()` (zeroes runtime timestamps, `reload()`, emits state) | `true` | `armReelSession(int count)` |
| `reelSessionState` | — | pull the reel-session snapshot | `{consumed: Int, allowance: Int, blocked: Bool, active: Bool}` | `reelSessionState() → Map` |

`reelSessionState` prefers the live `service.reelSessionSnapshot()`; if the service is
dead it synthesizes from `ConfigStore` (`consumed`/`allowance` from stored state). Both
`active` and `blocked` are AND-ed with "plan is `ONE_REEL`"
(`blocked = active && consumed >= allowance`).

### Conscious bank control

Resetting the Conscious earn-bank is a **separate imperative command**, not a
`pushSettings` side effect — so an auto-revert *into* Conscious (after an override that
ran from a Conscious base) keeps the earned bank; only a genuine user entry empties it
(semantics in [05-plans-pause-conscious.md](05-plans-pause-conscious.md) §5.4).

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `resetConsciousBank` | — | `store.resetConsciousBank()` (no-arg; bank→0 — the tick anchor is runtime-only in the service); then `service.onConsciousBankReset()` (drops the cached bank + pending unflushed accrual, `reload()`) | `true` | `resetConsciousBank()` |

Fired only by `SettingsCubit.enterConscious()` (Dart), which `await`s it right after
setting the plan to `CURIOUS`.

### Device / stats / snapshots (return maps)

| Method | Args | Returns (map shape) | Dart wrapper |
|---|---|---|---|
| `blockStats` | — | `{today: Int, total: Int, date: String}` — `date` is today's `dd-MM-yyyy` key (`DateKeys.today()`); `ConfigStore.blockStats(dateKey)` does **read-time day rollover**, so after midnight `today` reads `0` before the day's first block instead of yesterday's number | `blockStats() → Map` |
| `consciousState` | — | `{bankMs: Long, maxBankMs: Long, watching: Bool, blocked: Bool, active: Bool}` | `consciousState() → Map` |
| `contentCounterSnapshot` | — | `{enabled: Bool, bubbleEnabled: Bool, today: Int, total: Int, date: String, perAppToday: Map<String,Int>, perAppTotal: Map<String,Int>, timeTodayMs: Long, timeTotalMs: Long, bubbleStyle: String, widgetStyle: String}` | `contentCounterSnapshot() → Map` |
| `deviceInfo` | — | `{brand, manufacturer, model, sdkInt}` | *(no Dart wrapper)* |
| `installedPackages` | — | `List<String>` of launchable packages, or `null` on failure | `installedPackages() → Set<String>?` |
| `installedApps` | — | `List<{package: String, label: String, icon: ByteArray?}>` (icon = 96px PNG), or `null` on failure | `installedApps() → List<InstalledApp>?` |
| `unsupportedBrowsers` | — | `List<{packageName: String, label: String}>` — installed browsers **outside** `KNOWN_BROWSERS`, sorted by label; `[]` when all covered, `null` on failure | `unsupportedBrowsers() → List<String>?` (labels) |

Notes:
- **`consciousState`** prefers the live service snapshot; if the service is dead it
  synthesizes from `ConfigStore` (`bankMs`/`maxBankMs`/`active` from stored state,
  `watching:false`). `active`/`blocked`/`watching` are all AND-ed with
  "plan is `CURIOUS`".
- **`contentCounterSnapshot`** prefers the live service counter, else reads
  `ContentCounterStore` directly (works with the service dead). On a date rollover
  `today`/`perAppToday` read as `0`/`{}`.
- **`installedPackages`** runs off the platform thread (launchable-app enumeration
  can take 100s of ms) and posts back on it. It returns **`null`** (not empty) on
  failure so Dart treats install state as "unknown" and shows the full blocklist
  rather than hiding every app.
- **`installedApps`** is the picker-grade variant: the same MAIN/LAUNCHER walk
  plus per-app `loadLabel` and a 96px PNG rasterization of `loadIcon` (adaptive /
  vector / bitmap all drawn at target bounds). Also off-thread; Detoxo's own
  package is excluded; a single bad icon degrades to `icon: null` (per-app
  try/catch) instead of failing the list. Dart caches the result process-wide
  in `EngineRepositoryImpl` — the payload (~1–3 MB with icons) crosses the
  channel once per launch, not per picker open.
- **`unsupportedBrowsers`** (EVO-047) resolves `ACTION_VIEW` for `http`/`https` —
  the definitive "is a browser" test — and subtracts
  `BrowserUrlExtractor.isBrowser`, i.e. everything the web blocker can actually
  read. The manifest already declares both `<queries>` intents for browser
  visibility, so no `QUERY_ALL_PACKAGES` is involved. Off-thread like its two
  neighbours. `[]` and `null` mean different things and are not collapsed:
  `[]` is "every browser you have is covered", `null` is "couldn't ask" — the
  Website blocker renders a notice only for a **non-empty** list, so an
  unanswered query never invents a warning.

### Content-counter controls

| Method | Args | Native effect | Returns | Dart wrapper |
|---|---|---|---|---|
| `setContentCounterEnabled` | `{enabled: Bool}` (missing → no-op) | `store.enabled`; `service.contentCounter.setEnabled` | `true`; `false` when `enabled` is absent/malformed (nothing written) | `setContentCounterEnabled({enabled})` |
| `setContentBubbleEnabled` | `{enabled: Bool}` (missing → no-op) | `store.bubbleEnabled`; `service.contentCounter.setBubbleEnabled` | `true`; `false` when `enabled` is absent/malformed | `setContentBubbleEnabled({enabled})` |
| `pinContentWidget` | — | `AppWidgetManager.requestPinAppWidget(ContentCounterWidgetProvider)` | `Boolean` (false if launcher can't pin / < API 26) | `pinContentWidget()` |
| `refreshContentWidget` | — | `ContentCounterWidgetProvider.pushUpdate(store.snapshot)` | `true` | `refreshContentWidget()` |
| `setCounterStyle` | `{bubble?: Map, widget?: Map}` | persists each present surface (`as? Map` — a malformed one is skipped) and live-re-renders **only that surface**: `bubble` → the visible bubble, `widget` → all pinned widgets | `true` | `setCounterStyle({bubble, widget})` |

The bubble's `BubbleRepository.canShow()` reads `canDrawOverlays` **tri-state**
(`invokeBoolOrNull`): `null` = the call didn't answer, rendered as unknown —
never as denied ([17](17-content-counter.md) §6.1).

**`setCounterStyle` payload** — each sub-map is a style *wire map*; only the keys
present are updated (the Dart wrapper uses null-aware spread `{'bubble': ?bubble,
'widget': ?widget}`, so absent surfaces are omitted entirely). Native stores each
as JSON and re-renders.

- `bubble` (from `BubbleStyle.toWire`,
  `lib/features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart`):
  `{variant: String, size: num, textScale: num, spacing: num, opacity: num, showLabel: bool, showTime: bool}`
  (`showTime` gates the bubble's tap-to-reveal-watch-time gesture; default `true`)
- `widget` (from `WidgetStyle.toWire`,
  `lib/features/content_counter/home_content_counter/domain/entities/widget_style.dart`):
  `{background: String, theme: String, density: String, showToday: bool, showLabel: bool, showTotal: bool, accentByUsage: bool}`

Every `ChannelMethods` constant now has a native `when` arm — the dead
declared-but-unhandled constants (`showOverlay`, `hideOverlay`,
`foregroundPackage`) were **deleted**: no callers, no native branches. An
unknown method still hits `else -> result.notImplemented()` → a
`PlatformException` that `EngineChannel._invoke` swallows to `null`.

(`deviceInfo` is the one asymmetry: handled natively but no Dart wrapper —
callable only via a raw `invokeMap('deviceInfo')`.)

---

## Event channel — `com.errorxperts.detoxo/events`

One multiplexed stream. Native posts through
`ServiceEventBus.post(type, data)` (`android/.../engine/ServiceEventBus.kt`), which
merges `data` with `{"type": type}` and delivers on the main thread **only while a
sink is registered** — i.e. while Dart is listening (`DetoxoEventStream.onListen`
sets the sink; `onCancel` clears it only if it is still the sink that instance
installed, so engine recreation can't null a live listener's sink). With the UI
dead, events are dropped; the block hot-path never depends on Dart. **Exception:
the last `serviceStatus` payload is sticky** — recorded even with no sink and
replayed to a late subscriber by `onListen` (`replayLastStatus()`), so a cold
start where `onServiceConnected` beats the Dart subscription still sees
`running:true`.

Dart side: `EngineChannel.events()` maps each payload to
`Map<String,dynamic>`, is a broadcast stream, and multiplexes on the `type` field.
Repositories filter by `e['type'] == ChannelEvents.<x>`. The stream is
**self-healing**: if the underlying EventChannel stream closes (native engine
detach/recreation), it re-subscribes after 1 s — cubits hold process-lifetime
subscriptions, and a silent close would otherwise freeze live counters and
status forever.

Every payload carries `type` plus the fields below.

| `type` | Emitted by | Payload (beyond `type`) | Dart consumer |
|---|---|---|---|
| `serviceStatus` | `DetoxoAccessibilityService` (connect / interrupt / unbind) | `{running: Bool}` | `engine_repository_impl.dart` |
| `blocked` | `DetoxoAccessibilityService.onDetected` / `onAppBlocked` | `{package: String, platformId: String, mode: String, today: Int, total: Int, reason: "PLAN" \| "APP_BLOCK" \| "SCHEDULE" \| "DAILY_LIMIT"}` — `platformId` is `"rule"` for a rule's HOME bounce, `"app_block"` for an App Blocker lock | `engine_repository_impl.dart` (status + block history; `reason` is not read) |
| `webBlocked` | `DetoxoAccessibilityService.handleBrowser` | `{source: "RULE" \| "ADULT", mode: "PRESS_BACK", today: Int, total: Int, host?: String}` — `host` only for `RULE` hits; adult-list blocks are counted, never named (EVO-018) | `web_block_stats_repository_impl.dart` |
| `consciousState` | `DetoxoAccessibilityService` (1 Hz accountant) | `{bankMs: Long, maxBankMs: Long, watching: Bool, blocked: Bool, active: Bool}` | `engine_repository_impl.dart` |
| `reelSessionState` | `DetoxoAccessibilityService` (One Reel / Unblock allow/block/arm) | `{consumed: Int, allowance: Int, blocked: Bool, active: Bool}` | `engine_repository_impl.dart` |
| `contentCounted` | `ContentCounter.count` | `{package: String, today: Int, total: Int, perAppToday: Map<String,Int>, perAppTotal: Map<String,Int>, timeTodayMs: Long, enabled: Bool, bubbleEnabled: Bool}` | `content_counter_repository_impl.dart` |
| `blockScreenAction` | `BlockScreenOverlay` (a button on the wall) | `{action: "GO_HOME" \| "OPEN_APP" \| "DISMISS" \| "UNBLOCK", referenceType: String, referenceId: String, preview: Bool}` — `preview` is true for the editor's "Try it" wall. `UNBLOCK` fires since M8, but the flow it starts does **not** ride this event — the target is handed over by `takePendingUnblock`, which survives the cold start this event does not ([31](31-locked-rules-and-unblock.md) §5) | `native_event_reporter.dart` (analytics only — `referenceId` is never forwarded; no Dart navigation, see [25](25-block-screen.md) §8) |
| `ruleBoundary` | `DetoxoAccessibilityService.checkRuleBoundary` (every `WINDOW_STATE_CHANGED`) / `WatchdogJobService` (15-min tick) | `{atMs: Long}` — the pushed `nextBoundaryMs` has passed (a rule window opened or closed); posted **once**, then the boundary is zeroed until the next `pushRules` | `engine_repository_impl.dart` → `RulesCubit.resync()` re-resolves and re-pushes ([27](27-rules-engine.md) §5) |
| `nudgeShown` | `DetoxoAccessibilityService.showNudge` (only after the card actually attached) | `{package: String, elapsedMs: Long, thresholdMs: Long}` — `elapsedMs` is the real time in the app, `thresholdMs` the multiple that was crossed | `native_event_reporter.dart` → Firebase `nudge_shown` with **`duration_min` only**; `package` never leaves the device ([30](30-soft-nudge.md) §7) |

`mode` on `blocked` is the resolved block mode: `PRESS_BACK` \| `KILL_APP` \|
`LOCK_SCREEN` \| `NONE` — or `HOME` with `platformId: "app_block"` for a custom
whole-app block (`onAppBlocked`), which records to the same today/total counters.
`contentCounted` carries `enabled`/`bubbleEnabled` because Dart's stream mapper
defaults missing flags to `true` — a streamed update without the real values
used to corrupt the toggles' state. `consciousState.watching`/`blocked` are AND-ed with "plan
is `CURIOUS`" (the Conscious plan); `reelSessionState.blocked`/`active` are AND-ed
with "plan is `ONE_REEL`" (`blocked = active && consumed >= allowance`).

Every `ChannelEvents` constant has a live native emitter — the inert reserved
constants (`detection`, `foregroundChanged`) were **deleted**: no native emitter
ever posted them and no Dart consumer read them.

---

## Home-screen widget (over the command channel)

The home-screen reel-counter widget is driven by exactly two commands above —
`pinContentWidget` and `refreshContentWidget` — through
`lib/features/content_counter/home_content_counter/data/repositories/home_widget_repository_impl.dart`
(`pin()` / `refresh()`). The native provider renders from `ContentCounterStore`
(the **native store is the source of truth**); nothing is written from Dart.
The former `home_widget` plugin side-bridge was removed: its `saveWidgetData`
keys were never read natively, it rendered every pinned widget twice per push,
and its `requestPinWidget` never threw, so the launcher-can't-pin case was
misreported as success.

---

## Contract summary

- **2 channels**: commands (Method) + events (Event), both under
  `com.errorxperts.detoxo/*`, wired in `MainActivity`.
- **Commands**: string-dispatched in `CommandHandler`; returns are `Boolean`
  (queries/launches/actions), `true` (fire-and-forget mutations), a `Long`
  (`lastScreenOff`), a map (stats/snapshots/deviceInfo/`monotonicNow`), or
  a `List`/`null` (installedPackages). Every declared constant has a native
  arm; unknown methods → `notImplemented`.
- **Events**: 9 live types multiplexed by `type`; every declared constant has
  a native emitter. M8 deliberately added none — a grant's expiry is enforced
  natively and the countdown is cleared by a one-shot Dart timer
  ([31](31-locked-rules-and-unblock.md) §6).
- **Errors**: only `queryAppUsage` / `queryUsageEvents` ever `result.error(...)`
  (`BAD_ARGS`, `USAGE_ACCESS_DENIED`, `USAGE_QUERY_FAILED`); every other arm is
  fail-safe (`success` or `notImplemented`).
- **Widget**: `pinContentWidget` / `refreshContentWidget` on the command channel;
  provider `ContentCounterWidgetProvider`, native store is source of truth.

See also [03-detection-engine.md](03-detection-engine.md) for how `blocked` is
produced, and the content-counter engine doc for `contentCounted`
and the bubble/widget surfaces.

## Source files

- `lib/core/constants/channel_constants.dart`
- `lib/core/platform_channels/engine_channel.dart`
- `lib/core/platform/platform_capabilities.dart`
- `lib/features/blocking/shared/data/repositories/engine_repository_impl.dart`
- `lib/features/blocking/shared/domain/entities/enums.dart`
- `lib/features/limits/web_blocker/data/repositories/web_block_stats_repository_impl.dart`
- `lib/features/limits/rules/domain/rule_sync.dart`, `lib/features/limits/rules/domain/entities/rule_snapshot.dart` (the `pushRules` payload — [27](27-rules-engine.md))
- `lib/features/limits/unblock/domain/unblock_sync.dart`, `.../domain/entities/temporary_unblock.dart` (the `pushTemporaryUnblocks` payload — [31](31-locked-rules-and-unblock.md))
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/UnblockRegistry.kt`
- `lib/features/content_counter/content_counter_core/data/repositories/content_counter_repository_impl.dart`
- `lib/features/content_counter/content_counter_core/data/repositories/counter_appearance_repository_impl.dart`
- `lib/features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart`
- `lib/features/content_counter/home_content_counter/domain/entities/widget_style.dart`
- `lib/features/content_counter/home_content_counter/data/repositories/home_widget_repository_impl.dart`
- `lib/features/blocking/block_screen/data/repositories/block_screen_repository_impl.dart`
- `lib/features/blocking/block_screen/domain/entities/{block_screen_payload,block_screen_style}.dart`
- `lib/features/usage/data/repositories/usage_repository_impl.dart`
- `lib/core/services/firebase/analytics/native_event_reporter.dart`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenOverlay.kt`, `BlockScreenRenderer.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/UsageQuery.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/MainActivity.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/DetoxoEventStream.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ServiceEventBus.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounterStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/widget/ContentCounterWidgetProvider.kt`
