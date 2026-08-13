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
                                          └─ WebBlockEngine
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

On `onServiceConnected` the service sets its static `instance`, loads config, calls `startAsForeground()`, and posts a `serviceStatus {running:true}` event.

`startAsForeground()`:

- Creates notification channel `detoxo_protection_channel` (name **"Detoxo Service Status"**, `IMPORTANCE_LOW`, no badge, description "Focus protection active") on API 26+.
- Builds an ongoing, `PRIORITY_MIN` notification ("Detoxo is active" / "Monitoring and blocking short-form video.", small icon `ic_launcher`).
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
| `onServiceConnected` | set `instance`, load config, start FGS, emit `serviceStatus{running:true}` |
| `onAccessibilityEvent` | the hot-path: content-count pass → block gate → detection → block/Conscious (see [03](03-detection-engine.md)) |
| `onInterrupt` | emit `serviceStatus{running:false}` |
| `onTaskRemoved` | re-arm the FGS so swiping the app away does not kill protection |
| `onUnbind` / `onDestroy` | clear `instance`, stop the Conscious ticker, dispose the counter, emit `serviceStatus{running:false}` |

### Static handle

`DetoxoAccessibilityService.instance` (volatile, private-set) is the bridge everything else uses: `CommandHandler` reaches the live service through it (`instance?.reload()`, `instance?.contentCounter`, `instance?.consciousSnapshot()`, `instance?.armReelSession()`, `instance?.reelSessionSnapshot()`, etc.). `isRunning()` returns whether `instance != null`. Every call site null-checks, so commands degrade gracefully when the service is disabled.

**One Reel / Unblock runtime state.** The `oneReel` plan (allow N reels, then block — algorithm in [03-detection-engine.md](03-detection-engine.md) §5.3) keeps two `@Volatile` wall-clock timestamps on the service (`lastScrollAtMs`, `lastAllowAtMs`) that are meaningless across a restart, so `armReelSession()` zeroes them, `reload()`s, and emits fresh state. The consumed-count itself lives in `ConfigStore` (`reels_consumed`) and is **persisted**, so an OS-driven service restart keeps the user blocked until an explicit re-tap — the volatile timestamps self-correct from the persisted count. `reelSessionSnapshot()` (`{consumed, allowance, blocked, active}`) mirrors `consciousSnapshot()` and backs both the `reelSessionState` event and its pull query.

Note the service is **never** started manually. An enabled AccessibilityService is bound (and re-bound after reboot) by the OS — which is exactly why `BootReceiver` does nothing but log (§5).

---

## 3. CommandHandler (Dart → native)

`channels/CommandHandler.kt` implements `MethodChannel.MethodCallHandler`. It is the single entry point for every Dart-initiated command. It holds a `ConfigStore` and an optional `Activity` (for launching Settings screens), plus a single-thread `ioExecutor` for the one potentially-slow call (`installedPackages`).

Broadly the methods fall into four groups. (Argument/return shapes are in [18-platform-channel-contracts.md](18-platform-channel-contracts.md).)

**Config / settings push** — write to `ConfigStore`, then `DetoxoAccessibilityService.instance?.reload()`:
`pushConfig`, `pushSettings`, `pushWebBlocklist`, `pushProtectedApps`.

- `pushSettings` unpacks `activePlan`, `defaultBlockMode`, `enabledPlatforms`, `vibration`, `masterEnabled`, `pauseUntil`, `reelAllowance`, `consciousEarnDivisor`, `consciousMaxBankMs`, `blockAdultWebsites`, `blockWebsitesForBlockedApps`. The `activePlan` is stored **verbatim** — the old auto-reset of the Conscious bank on a `*→CURIOUS` transition was **removed**, so an auto-revert *into* Conscious (after an override that ran from a Conscious base) keeps the earned bank; the fresh-start reset now lives in the separate `resetConsciousBank` command below. `reelAllowance` is stored as the target (survives restart) but the One Reel / Unblock **consumed-count is not reset here** — only the imperative `armReelSession` re-arms, so an unrelated push can't refill a spent session.

- `pushProtectedApps` stores the enabled privacy-protected package names as a
  `StringSet` (`protected_packages`); the service caches it in a `@Volatile` set
  on `reload()` and does **nothing at all** while one of those apps is the event
  source or the focused window — no counting, no URL reads, no tree walks, no
  blocking, and `performBackInternal`/`killApp`/`lockScreen` are individually
  guarded as fail-closed backstops. See [24-protected-apps.md](24-protected-apps.md).

**Permission queries & launches** — pure platform checks and Settings intents:
`isAccessibilityEnabled`, `openAccessibilitySettings`, `canDrawOverlays`, `requestOverlayPermission`, `hasUsageAccess`, `openUsageAccessSettings`, `isIgnoringBatteryOptimizations`, `requestIgnoreBatteryOptimizations`, `isDeviceAdminActive`, `requestDeviceAdmin`, `removeDeviceAdmin`.

- `isAccessibilityEnabled` reads `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES` and matches our `ComponentName` case-insensitively in **both** flattened forms — long (`pkg/pkg.Class`) and short (`pkg/.Class`), since some OEM ROMs write the short one. It does **not** rely on the service's `instance`, so it is correct even before first bind. A false negative here would push an already-granted user into the restricted-settings recovery flow, hence accepting both.
- `hasUsageAccess` uses `AppOpsManager` (`OPSTR_GET_USAGE_STATS`), API-versioned (`unsafeCheckOpNoThrow` on Q+).
- Device-admin add/remove go through `DevicePolicyManager` against `DetoxoDeviceAdminReceiver` (§6).
- `launch(intent)` prefers the held `Activity`; with none it adds `FLAG_ACTIVITY_NEW_TASK` and starts from the app context. All launches are wrapped in try/catch and return a boolean.

**Direct block actions & stats** — forwarded to the live service:
`performBack`, `killApp` (needs a `package`), `lockScreen`, `consciousState`, `resetConsciousBank`, `armReelSession`, `reelSessionState`, `blockStats`.

- `consciousState` returns the live `instance?.consciousSnapshot()`, else a store-derived fallback map so the UI still gets a sensible value when the service is dead.
- `resetConsciousBank` empties the Conscious earn-bank (`store.resetConsciousBank(now)` → bank→0, anchor→now) and `reload()`s. It is the **only** bank-reset path (the old `pushSettings` plan-transition reset is gone), fired only by Dart's `SettingsCubit.enterConscious()` on a genuine user entry — so an auto-revert into Conscious keeps the bank. The service's own `accountConscious` accountant also **freezes** the bank during a live Pause (`now < pauseUntil`), mirroring its master-off freeze, so a paused Conscious base doesn't accrue free allowance ([03](03-detection-engine.md) §5.2).
- `armReelSession` ((re)arm One Reel / Unblock): reads `count` (clamped 1..20), sets `store.reelAllowance` + `activePlan = "ONE_REEL"`, calls `store.resetReelSession()` (consumed→0), then `instance?.armReelSession()`. Imperative so an unrelated `pushSettings` never re-arms mid-session.
- `reelSessionState` returns the live `instance?.reelSessionSnapshot()`, else a store-derived fallback (`consumed`/`allowance` from prefs, `blocked = consumed >= allowance` AND-ed with plan `ONE_REEL`).

**Content counter & widget** — see §7/§8:
`contentCounterSnapshot`, `setContentCounterEnabled`, `setContentBubbleEnabled`, `refreshContentWidget`, `setCounterStyle`, `pinContentWidget`.

**Device / package info**:
`deviceInfo` (brand/manufacturer/model/sdkInt); `installedPackages` runs `queryLaunchablePackages()` on the `ioExecutor` and posts the result back on the platform thread (Flutter requires the reply on the main thread). It enumerates `MAIN`/`LAUNCHER` activities and de-dups by package, returning **`null` (not empty)** on failure so Dart treats install-state as "unknown" and keeps showing the full blocklist rather than hiding every app.

The Conscious plan token is `PLAN_CONSCIOUS = "CURIOUS"` — the internal/wire value is `CURIOUS`; its user-facing label is **"Conscious"**. Do not rename the token. The One Reel / Unblock token is `PLAN_ONE_REEL = "ONE_REEL"`.

Any unrecognized method returns `result.notImplemented()`.

---

## 4. ServiceEventBus & the in-process event bridge

Native → Dart events use two small classes:

- **`engine/ServiceEventBus.kt`** — a singleton `object` with a `@Volatile var sink: Sink?`. The service calls `ServiceEventBus.post(type, data)`, which merges `data` with `{"type": type}` and delivers it to the sink **on the main thread** (`Handler(Looper.getMainLooper())`). If no sink is registered (UI dead / not listening), the event is silently dropped — the block hot-path never depends on it.
- **`channels/DetoxoEventStream.kt`** — the `EventChannel.StreamHandler`. `onListen` installs a sink that forwards to `events.success(...)`; `onCancel` clears it. So the bus is "connected" only while Dart is actively listening on `com.errorxperts.detoxo/events`.

Event `type` values emitted by the native layer: `serviceStatus`, `detection`, `blocked`, `webBlocked`, `foregroundChanged`, `consciousState`, `reelSessionState`, `contentCounted`. Payload shapes are in [18](18-platform-channel-contracts.md). The events are multiplexed onto the single channel and demultiplexed on the Dart side by the `type` field.

---

## 5. BootReceiver (log-only)

`receivers/BootReceiver.kt` is a `BroadcastReceiver` registered in the manifest for `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, and `QUICKBOOT_POWERON`. Its `onReceive` does exactly one thing: `Log.i("DetoxoBoot", "received <action>")`.

It intentionally does **not** restart the service. An enabled AccessibilityService is re-bound automatically by the OS after boot/update, so there is nothing to do. There is no date-changed receiver and no custom command broadcast — all commands arrive over the MethodChannel. The receiver exists mainly as a hook point (and for the manifest declaration) should a "re-enable me" nudge ever be wired up.

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
- **Silently no-ops without overlay permission** — `show()` returns early if `!Settings.canDrawOverlays(context)`. `addView`/`updateViewLayout`/`removeView` are all try/caught so a revoked permission or a race can't crash the service.

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

---

## 8. ContentCounterWidgetProvider (home-screen widget)

`widget/ContentCounterWidgetProvider.kt` is an `AppWidgetProvider` for a **2×2** home-screen widget showing today's reel count + all-time total.

- **Single source of truth**: `ContentCounterStore` (`detoxo_engine_prefs`). The widget reads `snapshot(dateKey())` directly, so it is correct even when the Flutter UI is dead. Persisted counts live under keys `cc_today` / `cc_total` (per-app maps under `cc_per_app_today` / `cc_per_app_total`).
- **Live updates are pushed natively**: `updatePeriodMillis=0` (no polling). The native counting brain calls `ContentCounterWidgetProvider.pushUpdate(context, snapshot)` on each counted reel (throttled) and on style changes; `pushUpdate` is a cheap no-op when no instances are pinned.
- **Bitmap-rendered face**: the widget draws to a `Bitmap` via `WidgetBitmapRenderer` (honouring the user's chosen glass background/theme/density and the persisted `widgetStyle` JSON) and sets it into `RemoteViews`. It re-renders on `onAppWidgetOptionsChanged` (resize) at the launcher-reported size, clamped to bound bitmap memory.
- **Tap** → launches the app via a `PendingIntent` (`FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE`).
- **Pin request**: `CommandHandler.pinContentWidget()` calls `AppWidgetManager.requestPinAppWidget(...)` (API 26+, guarded by `isRequestPinAppWidgetSupported`).

Provider metadata (`res/xml/content_counter_widget_info.xml`): `minWidth/minHeight 110dp`, `targetCell 2×2`, `updatePeriodMillis=0`, `resizeMode horizontal|vertical`, `widgetCategory home_screen`, initial + preview layouts. Note this is the **native** widget surface; the Dart side integrates via the `home_widget` package but the on-device render and reads are done here in Kotlin.

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
- **`.receivers.BootReceiver`** — exported, filters `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` / `QUICKBOOT_POWERON`.
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
| `accessibilityEventTypes` | `typeAllMask` (need window-state + content + scroll to catch reels) |
| `accessibilityFeedbackType` | `feedbackGeneric` |
| `accessibilityFlags` | `flagDefault \| flagRetrieveInteractiveWindows \| flagReportViewIds \| flagRequestFilterKeyEvents \| flagIncludeNotImportantViews` |
| `canRetrieveWindowContent` | `true` (read node trees) |
| `canRequestFilterKeyEvents` | `true` |
| `canPerformGestures` | `true` (global-action back / future gesture blocks) |
| `notificationTimeout` | `100` ms |
| `description` / `summary` | `@string/accessibility_service_description` / `@string/accessibility_service_summary` |

`flagRetrieveInteractiveWindows` + `flagReportViewIds` are what make the 3-stage view-id detection ([03](03-detection-engine.md)) possible — reading the foreground app's view tree and resource-ids.

### `device_admin_policies.xml`

`force-lock` + `watch-login` only (see §6).

### `content_counter_widget_info.xml`

See §8.

### `strings.xml`

`app_name` (Detoxo), the accessibility description/summary, `device_admin_label`/`device_admin_description`, and `cc_widget_description` ("Reel counter").

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
- `android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/BootReceiver.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/admin/DetoxoDeviceAdminReceiver.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/ContentCounterBubble.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/widget/ContentCounterWidgetProvider.kt`
- `android/app/build.gradle.kts`
