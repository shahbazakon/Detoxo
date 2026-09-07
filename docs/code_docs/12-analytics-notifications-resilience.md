# Analytics, Notifications & Resilience

How Detoxo counts what it blocked, keeps its engine alive and OS-visible,
survives reboots/updates, and (optionally) protects itself
from being uninstalled. The block counts documented here are **native and
on-device** — nothing about a block is uploaded. They are distinct from the app's
separate **Firebase telemetry layer** (usage analytics, Crashlytics, Performance),
which *does* send anonymised data off-device — see
[19-firebase-telemetry.md](19-firebase-telemetry.md). FCM push is still not bundled.

Related docs: [03-detection-engine.md](03-detection-engine.md) (where `blocked`
events originate), [17-content-counter.md](17-content-counter.md) (the parallel,
decoupled counting pipeline), [13-onboarding-permissions.md](13-onboarding-permissions.md)
(how Device Admin / notifications are requested).

---

## 1. Block counts (the Activity tab's "Blocked" tiles and rows)

What Detoxo blocked is counted **natively**, not in Dart.
`ConfigStore.recordBlock(dateKey, yesterdayKey, pkg)` keeps, in its
SharedPreferences and all rolled by `block_date` ([09](09-persistence-data-model.md)):

| Key | What |
|---|---|
| `block_today` / `block_total` | the counters, with read-time midnight rollover — after midnight `today` reads 0 before the day's first block |
| `block_by_pkg_today` | today's per-package tally, `{pkg: count}` JSON, at most 20 packages — a newcomer past the cap evicts the smallest entry (EVO-059) |
| `block_yesterday` / `block_yesterday_date` | the count that was "today" when the day last changed, rotated in by the first block of the new day and read back only while its date is exactly yesterday (EVO-060) |

The arithmetic is the pure `engine/BlockTally.kt` (`record` / `parse` / `without` /
`yesterday`), pinned on the JVM by `BlockTallyTest`; `DateKeys.dayBefore(now)`
supplies yesterday's key by Calendar arithmetic, so a DST day is still one day.
Every `blocked` event and the `blockStats` reply carry `today`, `total`,
`yesterday` and `byPackage` ([18](18-platform-channel-contracts.md));
`EngineRepositoryImpl._readCounts` folds them into `ServiceSnapshot`
(`blocksToday`, `blocksTotal`, `blocksYesterday`, `blocksByPackage`) with `as num?`
reads — a throwing cast inside that `async*` would end the subscription and freeze
every tile for the process. The snapshot is held by the app-wide `ServiceCubit`
(`main.dart`) and re-read on every app resume (`AppResumeSync` →
`ServiceCubit.refresh()`, §3.2) and on the Activity tab's pull-to-refresh, because
native rolls `today` over at read time and there may be no `blocked` event to
carry the new day in.

The Activity screen (`lib/features/analytics/presentation/analytics_screen.dart`,
layout in [28](28-insights.md) §6) draws them as one flat `StatCard` in the
**Today** panel (`widgets/today_overview.dart`) — **Blocked**, with
`Yesterday: N` as its one caption once there is any history (`All time: N` before
then); never a percentage, today is still running — via `context.select`, and as the **Blocks**
segment of the **By app** section (`widgets/by_app_section.dart`): one `AppLimitRow`
per package, most-blocked first with a bar relative to the most-blocked app, each
opening the rule editor pre-filled with a daily limit for that app (EVO-033's rule,
shared with the Reels and Time segments). Labels and icons are `InsightsState.apps` —
the Activity screen's one installed-app lookup, resolved by `InsightsCubit` on every
refresh whatever the usage grant said, from the engine's process-cached list; a
failure costs the labels, never the rows. The row-building (sort, cap, bar
normalisation) is the pure `ByAppSection.rowsFor`, unit-tested in
`test/by_app_rows_test.dart`. Because
the counters are native, every number is right for blocks that happened while the
app was closed. `ServiceCubit` is reached through the `blocking.dart` barrel
(exported like `settings_cubit`), which keeps `tool/check_boundaries.sh` clean.

Protected apps never enter the tally — the service's privacy guard precedes every
block — and a package protected later leaves it at once: the `pushProtectedApps` arm
calls `ConfigStore.scrubBlockTally` ([24](24-protected-apps.md)).

### 1.1 What was removed, and why

Until this change the `analytics` feature also carried a Dart-side **block-event
buffer**: `AnalyticsRepository` / `AnalyticsRepositoryImpl` over
`StoreKeys.analyticsEvents` (`analytics_events`, a capped newest-first JSON list of
`{platformId, packageName, mode, ts}`), fed by `AnalyticsCubit` subscribing to
`EngineRepository.blockStream()`. Its only reader was an **Events** feed — one
tile per block — behind a segmented **Insights | Events** control on the Activity
tab. The cubit was created per Activity mount, so the buffer only recorded blocks
**while the Activity view was open**: its "today" was never the real number, and
the count tile that replaced the feed needed the native counters anyway.

The feed, the segmented control, the cubit, the repository and its interface, the
DI registration, the store key and `test/analytics_buffer_test.dart` are gone. An
upgraded install's stale `analytics_events` document (up to 500 records — tens of KB
that a non-lazy box decoded into RAM on every cold start) is deleted once at bootstrap
(`lib/app/bootstrap.dart`, the `unblocks` step beside `migrateWebPauses`; a missing key
is a no-op); nothing reads it. Nothing ever uploaded from it, and
nothing does now — the block counts are local, and the Firebase layer
([19](19-firebase-telemetry.md)) records block *categories*, not this count.

The `analytics` feature is therefore **insights** ([28](28-insights.md)) plus the
Activity screen that hosts it; its barrel exports the insights domain only.

---

## 2. Status notification (foreground service)

Detoxo's engine is an `AccessibilityService`
(`accessibility/DetoxoAccessibilityService.kt`) running in the main process —
there is no separate `:as_process` — and it **is a foreground service**:
`onServiceConnected` calls `startAsForeground()`, which promotes the service
with `startForeground(NOTIF_ID, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)`
on Android 14+ (`UPSIDE_DOWN_CAKE`), else the 2-arg overload. The ongoing
notification is what makes the always-on protection visible to the user.

### 2.1 Channel & notification (verbatim from `startAsForeground()`)

| Field | Value |
|---|---|
| Channel id (`CHANNEL_ID`) | `detoxo_protection_channel` |
| Channel name | `Detoxo Service Status` |
| Channel importance | `IMPORTANCE_LOW` (silent, no sound/heads-up) |
| Channel flags | `setShowBadge(false)`, description `"Focus protection active"` |
| Notification id (`NOTIF_ID`) | `1125` |
| Title | `Detoxo is active` |
| Text | `Monitoring and blocking short-form video.` |
| Small icon | `R.mipmap.ic_launcher` |
| Ongoing | `true` |
| Priority | `PRIORITY_MIN` |
| FGS type | `FOREGROUND_SERVICE_TYPE_SPECIAL_USE` (API 34+) |

The channel is created (API 26+/`O`) before the `NotificationCompat.Builder`
notification is shown. `IMPORTANCE_LOW` + `PRIORITY_MIN` + no badge make it a
quiet, persistent status entry rather than an alert.

### 2.2 Fail-soft promotion

The `startForeground(...)` call is wrapped in `try/catch` and only logs on
failure (never crashes) — protection keeps running even if the promotion or the
notification fails (e.g. `POST_NOTIFICATIONS` denied; the user just doesn't see
the status entry). Manifest support: the `FOREGROUND_SERVICE` and
`FOREGROUND_SERVICE_SPECIAL_USE` permissions are declared, and the `<service>`
carries `android:foregroundServiceType="specialUse"` with the required
`PROPERTY_SPECIAL_USE_FGS_SUBTYPE` property (see
[04-native-android-layer.md](04-native-android-layer.md) §9).

### 2.3 Lifecycle: when it starts, restarts, and reports status

`startAsForeground()` is invoked:

- in **`onServiceConnected()`** — right after config load, the first time the OS
  binds the enabled accessibility service; and
- in **`onTaskRemoved()`** — re-armed if the user swipes the app away.
  The service itself is unaffected: the system, not the task, owns its lifetime.

Service liveness is broadcast to Dart over the multiplexed EventChannel as
`serviceStatus` events (via `ServiceEventBus`):

| Callback | Emitted `serviceStatus` |
|---|---|
| `onServiceConnected()` | `{ running: true }` |
| `onInterrupt()` | `{ running: false }` |
| `onUnbind()` | `{ running: false }` (also clears `instance`, stops the Conscious accountant, disposes the counter) |
| `onDestroy()` | clears `instance`, stops the accountant, disposes the counter |

The last `serviceStatus` payload is **sticky**: `ServiceEventBus` records it
even when no Dart listener is attached, and `DetoxoEventStream.onListen` replays
it — so a cold start where `onServiceConnected`'s `running:true` fires before
Dart subscribes no longer leaves the dashboard stuck on "Protection off" (see
[04-native-android-layer.md](04-native-android-layer.md) §4).

A static `instance` / `isRunning()` also lets `CommandHandler` reach the live
service directly (e.g. `performBack`, `killApp`, and the accessibility-enabled
check).

### 2.4 Relationship to counters

The notification is only about **liveness**; it carries no live counts. Block
counters (`today`/`total`) live natively in `ConfigStore` and ride the `blocked`
/ status events, and the content-counter widget/bubble is a separate surface
(see [17-content-counter.md](17-content-counter.md)). Nothing updates the
notification text after it is first posted.

---

## 3. Resilience: BootReceiver + the protection watchdog

`receivers/BootReceiver.kt` is registered in the manifest (exported, with
`RECEIVE_BOOT_COMPLETED` permission) for three actions:

- `android.intent.action.BOOT_COMPLETED`
- `android.intent.action.MY_PACKAGE_REPLACED` (after an app update)
- `android.intent.action.QUICKBOOT_POWERON` (OEM quick-boot)

Its `onReceive` logs the action and **(re)schedules the watchdog job**
(`WatchdogJobService.schedule(context)`). The receiver must be
`exported="true"` for `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` (protected
broadcasts) — but `QUICKBOOT_POWERON` is an **unprotected OEM action any app
may send**, so the payload must stay an idempotent, harmless re-schedule;
never add state changes here (the manifest comment records the same
invariant). It deliberately does **not** restart
the service: an `AccessibilityService` that the user has enabled is re-bound
automatically by the OS after a reboot or package replacement — the app does
not (and cannot) manually start or rebind it. Liveness is judged by the job's
first periodic run rather than inline, because checking at boot time would race
the post-boot rebind. There is **no** date-changed receiver, no
`APP_COMMAND`-style broadcast entry point, and no manual service restart here —
runtime commands arrive over the `MethodChannel`, not broadcasts.

### 3.1 WatchdogJobService — the "Protection stopped" alert

Some OEMs (Realme/ColorOS force-stop, the EVO-013 finding) kill the
accessibility service silently and never rebind it; only a manual Settings
re-toggle recovers. Since a rebind cannot be forced, **detect + notify is the
ceiling** — and `receivers/WatchdogJobService.kt` is that ceiling: a persisted
periodic `JobScheduler` job (`JOB_ID 1126`, 15-minute period, survives reboot)
scheduled idempotently from `onServiceConnected` and `BootReceiver`.

Each run checks `masterEnabled && instance == null && (accessibility enabled in
Settings || serviceEverConnected)` and, at most once per 6 hours
(`ConfigStore.lastWatchdogNotifiedMs`), posts the alert below. The debounce is
armed **only when the notification can actually reach the shade**
(`areNotificationsEnabled()` true and the channel not user-blocked;
`notifyProtectionStopped` returns whether it was handed over) — otherwise a
POST_NOTIFICATIONS denial would silently burn the 6-hour window and delay the
first real alert after the user grants it. On **recovery**
(the check finds the service alive, or `onServiceConnected` fires) `clearAlert`
cancels the notification and zeroes the debounce — a stale alert never outlives
the outage, and a fresh outage always re-notifies:

| Field | Value |
|---|---|
| Channel id | `detoxo_watchdog_channel` |
| Channel name | `Protection alerts` (`IMPORTANCE_DEFAULT`, description "Alerts when protection stops") |
| Notification id | `1127` |
| Title / text | `Protection stopped` / `Detoxo is no longer blocking. Tap to re-enable it.` |
| Tap action | deep link to `ACTION_ACCESSIBILITY_SETTINGS` (where the re-toggle happens) |
| Auto-cancel | `true` |

All four user-facing strings come from `res/values/strings.xml`
(`watchdog_channel_name` / `watchdog_channel_description` / `watchdog_title` /
`watchdog_text`); behavior is unchanged.

This is the notification promised by the permission funnel's "Alerts you if
protection stops" copy. Full mechanics in
[04-native-android-layer.md](04-native-android-layer.md) §5.

### 3.2 App-resume re-sync (Dart)

`lib/app/app_resume_sync.dart` (`AppResumeSync`, wrapped around the app in
`main.dart` next to `PinAutoRelock`) repairs Dart↔native drift on **every app
resume** — previously every sync ran only on a cold start through the splash,
so an app kept in recents for days never re-checked permissions and showed
yesterday's counts after midnight. On each resume (all fire-and-forget):

- **Cheap leg, every resume:** `PermissionsCubit.refresh()` (keeps the
  persisted granted set fresh), `ServiceCubit.refresh()` (un-sticks the
  "Protection off" card after a rebind), `ContentCounterCubit.refresh()` (the
  day-rollover UI repair), `SettingsCubit.resync()` (re-pushes a **fresh load**
  of the persisted settings — never the cubit's in-memory copy, which the Web
  Blocker's protection toggles bypass — without mutating anything). **Every
  cheap leg is wrapped in
  `guardedSync(name, future)`** (from `lib/app/engine_sync.dart`) — a flaky
  resume sync logs instead of surfacing as an uncaught-zone error (the legs
  used to be bare `unawaited` futures).
- **Heavy leg, throttled to ≥ 15 min** (`heavyLegInterval`; seeded at
  construction because the splash just ran the same syncs):
  `TargetsCubit.load()` (config re-push, also guarded) plus
  **`syncEngineBlocklists()`** — the single definition of the blocklist
  drift-repair trio (protected apps + web blocklist + app blocklist, each leg
  individually `guardedSync`-wrapped) in `lib/app/engine_sync.dart`, shared
  with the splash. The verbatim duplicated trio the splash and the resume path
  each used to carry is gone.

Covered by `test/resume_sync_test.dart`.

---

## 4. Resilience: Device Admin (optional uninstall protection)

Device Admin is **optional** and serves two purposes: (1) uninstall protection
while active, and (2) enabling the device-level `lockNow()` used by the
`LOCK_SCREEN` block mode.

### 4.1 Receiver & policy

`admin/DetoxoDeviceAdminReceiver.kt` extends `DeviceAdminReceiver` and only logs
its `onEnabled` / `onDisabled` transitions (no policy logic in code):

```kotlin
class DetoxoDeviceAdminReceiver : DeviceAdminReceiver() {
    override fun onEnabled(context: Context, intent: Intent)  { Log.i("DetoxoAdmin", "device admin enabled") }
    override fun onDisabled(context: Context, intent: Intent) { Log.i("DetoxoAdmin", "device admin disabled") }
}
```

The declared policies live in `res/xml/device_admin_policies.xml`:

```xml
<uses-policies>
    <force-lock/>     <!-- allows lockNow() -->
    <watch-login/>
</uses-policies>
```

Manifest registration: the receiver is `exported="true"`, guarded by
`android.permission.BIND_DEVICE_ADMIN`, points at the `device_admin_policies`
meta-data, and filters `android.app.action.DEVICE_ADMIN_ENABLED`.

### 4.2 Request / query / remove flow (via MethodChannel)

The admin lifecycle is driven from Dart (the permissions feature) through
`channels/CommandHandler.kt`:

| Command | Native action |
|---|---|
| `isDeviceAdminActive` | `DevicePolicyManager.isAdminActive(ComponentName(DetoxoDeviceAdminReceiver))` |
| `requestDeviceAdmin` | launches `ACTION_ADD_DEVICE_ADMIN` with `EXTRA_DEVICE_ADMIN` + an `EXTRA_ADD_EXPLANATION` ("Enable to protect Detoxo from being uninstalled while active.") |
| `removeDeviceAdmin` | `DevicePolicyManager.removeActiveAdmin(...)` (wrapped in try/catch) |

### 4.3 How it is used at block time

`LOCK_SCREEN` is the only block mode that touches Device Admin. In the service:

```kotlin
fun lockScreen() {
    val dpm = getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager
    val admin = ComponentName(this, DetoxoDeviceAdminReceiver::class.java)
    if (dpm.isAdminActive(admin)) dpm.lockNow()   // guarded — no-op if admin off
}
```

Because it is guarded by `isAdminActive`, `LOCK_SCREEN` silently degrades to
nothing if the user never granted admin. Per `enums.dart`, `LOCK_SCREEN` is
**retained for wire/config compatibility but is no longer offered in the
block-mode picker**; the default block mode is `PRESS_BACK`
(`performGlobalAction(GLOBAL_ACTION_BACK)`), and `LOCK_APP` currently degrades to
a back press (native app-lock enforcement is a documented follow-up). See
[03-detection-engine.md](03-detection-engine.md) for the full block-mode
resolution.

---

## 5. Summary of what is and isn't shipped

| Capability | Status |
|---|---|
| Block counts (native `block_today` / `block_total`, plus yesterday's rotated count and a bounded per-package tally — the Activity tab's **Blocked** tile and the **By app → Blocks** rows) | Shipped (EVO-059 / EVO-060) |
| Activity screen (tab + drawer route; three headed sections — Today, Distraction, By app — one glass panel each, then the Overrides card; the source note is behind an info button) | Shipped — layout in [28](28-insights.md) §6 |
| Foreground-service notification (`detoxo_protection_channel`, id `1125`, special-use FGS) | Shipped |
| Protection watchdog (`WatchdogJobService`, job `1126`; "Protection stopped" notification `1127` on `detoxo_watchdog_channel`) | Shipped — detect + notify only (a rebind cannot be forced) |
| BootReceiver (schedules the watchdog; OS auto-rebinds the accessibility service) | Shipped |
| App-resume re-sync (`AppResumeSync`: cheap refresh every resume, blocklist/config re-push ≥ 15 min) | Shipped |
| Device Admin uninstall protection + `lockNow()` for `LOCK_SCREEN` | Shipped, optional/opt-in |
| Firebase Analytics / Crashlytics / Performance (off-device telemetry) | **Shipped** — see [19-firebase-telemetry.md](19-firebase-telemetry.md) |
| FCM push | **Not bundled** |
| Dart block-event buffer + Events feed | **Removed** — it only saw blocks while the Activity view was open; the native counters are the record (§1.1) |
| Notification suppression (`DetoxoNotificationListener` cancels notifications from apps blocked right now) | Shipped, optional/opt-in and **off by default** — see [29](29-notification-suppression.md). The only notification surface Detoxo *consumes* rather than posts; it unbinds itself whenever it connects with the toggle off, reads a notification's package name, key, user and category only, lets messages and calls through (EVO-038), and never touches Detoxo's own `1125` / `1127` notifications. |
| `LOCK_SCREEN` block mode UI | Retained on the wire, removed from the picker |

---

## Source files

- `lib/features/analytics/analytics.dart`
- `lib/features/analytics/presentation/analytics_screen.dart` (the three-section scroll)
- `lib/features/analytics/presentation/widgets/today_overview.dart` (the **Blocked** tile)
- `lib/features/analytics/presentation/widgets/by_app_section.dart` (the **Blocks** segment rows)
- `lib/features/analytics/presentation/widgets/app_limit_row.dart`
- `lib/core/design_system/components/cards.dart` (`StatCard.caption`, `StatCard.compact`,
  `StatCard.contained`)
- `lib/features/blocking/blocking.dart` (exports `ServiceCubit`)
- `lib/features/blocking/engine/presentation/service_cubit.dart`
- `lib/features/blocking/shared/domain/entities/engine_event.dart` (`ServiceSnapshot`, `BlockEvent`)
- `lib/features/blocking/shared/domain/entities/enums.dart`
- `lib/features/blocking/shared/domain/repositories/blocking_repositories.dart`
- `lib/features/blocking/shared/data/repositories/engine_repository_impl.dart`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` (`recordBlock` / `blockStats` / `scrubBlockTally`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/BlockTally.kt` (+ `BlockStats`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DateKeys.kt` (`dayBefore`)
- `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/BlockTallyTest.kt`
- `test/activity_screen_test.dart`
- `lib/app/app_resume_sync.dart`
- `lib/app/engine_sync.dart` (`syncEngineBlocklists` + `guardedSync`)
- `test/resume_sync_test.dart`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/BootReceiver.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/WatchdogJobService.kt`
- `android/app/src/main/res/values/strings.xml` (`watchdog_*` notification strings)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/admin/DetoxoDeviceAdminReceiver.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `android/app/src/main/res/xml/device_admin_policies.xml`
- `android/app/src/main/AndroidManifest.xml`
