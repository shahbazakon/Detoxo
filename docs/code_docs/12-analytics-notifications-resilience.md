# Analytics, Notifications & Resilience

How Detoxo records what it blocked, keeps its engine alive and OS-visible,
survives reboots/updates, and (optionally) protects itself
from being uninstalled. The `analytics` **feature** documented here is **local and
on-device** — its block-event buffer never uploads. It is distinct from the app's
separate **Firebase telemetry layer** (usage analytics, Crashlytics, Performance),
which *does* send anonymised data off-device — see
[19-firebase-telemetry.md](19-firebase-telemetry.md). FCM push is still not bundled.

Related docs: [03-detection-engine.md](03-detection-engine.md) (where `blocked`
events originate), [17-content-counter.md](17-content-counter.md) (the parallel,
decoupled counting pipeline), [13-onboarding-permissions.md](13-onboarding-permissions.md)
(how Device Admin / notifications are requested).

---

## 1. Local analytics (block-event history)

The `analytics` feature is a thin, local **block-event buffer** plus a read-only
"Activity" feed. It records one record per native `blocked` event and shows the
recent history; there is no aggregation, upload, or dashboard beyond a list.

> The same feature also hosts **`insights/`** — the day rollups over real
> `UsageStatsManager` screen time, which share the Activity tab behind a
> segmented control but share no storage, no cubit and no repository with this
> buffer. They are documented separately in [28-insights.md](28-insights.md);
> everything in §1 below is the block-event buffer only.

### 1.1 Feature layout & boundary

```
lib/features/analytics/
  analytics.dart                                   # public barrel (domain only)
  domain/repositories/analytics_repository.dart    # AnalyticsRepository interface
  data/repositories/analytics_repository_impl.dart # LocalStore-backed impl
  presentation/analytics_cubit.dart                # AnalyticsCubit
  presentation/analytics_screen.dart               # AnalyticsScreen + AnalyticsTab
```

The barrel exports **only** the domain contract, so other features depend on the
interface, never the `LocalStore`-backed implementation or the UI (boundary
enforced by `tool/check_boundaries.sh`).

### 1.2 Domain contract

`AnalyticsRepository` is deliberately tiny:

```dart
abstract interface class AnalyticsRepository {
  Future<void> logBlock(BlockEvent event);
  Future<List<BlockEvent>> recent({int limit = 50});
  Future<int> countToday();
}
```

`BlockEvent` (defined in the blocking feature,
`lib/features/blocking/shared/domain/entities/engine_event.dart`) carries
`platformId`, `packageName`, `mode` (`BlockingMode`), and a `timestamp`.

### 1.3 Storage implementation

`AnalyticsRepositoryImpl` persists to the Dart key-value store
(`lib/core/storage/local_store.dart`) under key
`StoreKeys.analyticsEvents = 'analytics_events'` as a single JSON array. Key
behaviours:

- **Newest-first, capped at 500.** `logBlock` reads the existing list, prepends
  the new event, and truncates with `.take(_maxEvents)` where
  `_maxEvents = 500`. So the buffer is a rolling window of the most recent ~500
  blocks (older entries fall off).
- **Explicit wire (de)serialization.** Each record is
  `{ platformId, packageName, mode, ts }` where `mode` is `BlockingMode.wire`
  (e.g. `"PRESS_BACK"`, `"KILL_APP"`) and `ts` is
  `timestamp.millisecondsSinceEpoch`. Reads use `BlockingMode.fromWire(...)`,
  which falls back to `pressBack` for unknown/legacy tokens, and default empty
  strings / epoch-0 for missing fields — so a malformed record never throws.
- **`recent({limit})`** decodes the array and returns the first `limit`
  entries (default 50; the UI asks for 100). Returns `const []` when the key is
  unset.
- **`countToday()`** loads up to `_maxEvents` and counts entries whose
  `timestamp` falls on the local calendar day (year/month/day match
  `DateTime.now()`). This is the Dart-side "blocks today"; note the native engine
  keeps its own authoritative counters (see [03-detection-engine.md](03-detection-engine.md)
  and §2.4 below) — this local count is derived only from the buffered events.

> Design note (from the impl's own comment): the interface is the seam for a
> future cloud sink. "A cloud sink (Firebase Analytics) can be added behind the
> same interface later." That is a **planned swap-in**, not shipped — nothing
> uploads today.

### 1.4 Cubit — the sink and the loader

`AnalyticsCubit extends Cubit<List<BlockEvent>>` (state is just the list;
initial `const []`):

```dart
AnalyticsCubit(this._repo, this._engine) : super(const []) {
  _engine.blockStream().listen(_repo.logBlock);   // persist every block
}
Future<void> load() async => emit(await _repo.recent(limit: 100));
```

Two responsibilities:

1. **Persistence sink.** In its constructor it subscribes to
   `EngineRepository.blockStream()` and pipes every `BlockEvent` straight into
   `_repo.logBlock`. `blockStream()`
   (`lib/features/blocking/shared/data/repositories/engine_repository_impl.dart`)
   filters the multiplexed EventChannel for `type == "blocked"` and maps
   `platformId` / `package` / `mode` into a `BlockEvent`, stamping
   `timestamp: DateTime.now()` on the Dart side (the native `today`/`total`
   counters on that event feed the status stream, not the history record).
2. **UI loader.** `load()` reads the last 100 records for display.

> Caveat worth knowing: the sink lives on the cubit, and the cubit is created
> where the Activity view mounts (see §1.5). Persistence therefore runs while an
> Activity view has been opened at least once and its cubit is alive — it is not
> an app-lifetime background logger. The native engine's own counters and events
> are the source of truth for "what was blocked"; this buffer is a UI-facing
> convenience history.

### 1.5 Presentation — one cubit, two entry points

`analytics_screen.dart` exposes the same feed two ways that differ only in
chrome, both wired through `_withCubit(...)` — a `MultiBlocProvider` supplying an
`AnalyticsCubit` (`sl<AnalyticsRepository>()`, `sl<EngineRepository>()`) and an
`InsightsCubit` (`sl<InsightsRepository>()`, `sl<EngineRepository>()`), both
already `..load()`-ed; the `ContentCounterCubit` comes from `main.dart`:

- **`AnalyticsScreen`** — full-screen drawer route ("Activity") with a
  `GlassAppBar` + back button.
- **`AnalyticsTab`** — the second HomeShell tab, with an in-tab header, a
  feedback button, and a drawer menu button, wired to the floating nav bar's
  scroll controller for hide-on-scroll.

The body (`_ActivityBody`) is a stateful, always-scrollable `ListView` inside a
`RefreshIndicator`, led by a `GlassSegmented` **Insights | Events** control.
Insights is the default segment and renders `InsightsView` ([28](28-insights.md));
pull-to-refresh recomputes it. The **Events** segment is this buffer: the
always-visible `ReelCounterCard` (from the content-counter feature), then either
an `EmptyState` ("Nothing blocked yet" / "Block events will show up here as they
happen.") or one `_EventTile` per event. A tile renders a red "ban" `IconBadge`,
`platformId` as the title, `packageName · mode.wire` as the subtitle, and a
`DateFormat('MMM d, HH:mm')` timestamp.

### 1.5a Lifetime and write safety

`AnalyticsCubit` holds its `blockStream()` subscription and cancels it in
`close()`. It is constructed per `_ActivityBody` mount and `AnalyticsScreen` is
a pushed drawer route, so without the cancel every visit left a permanent
listener behind — and each one ran its own read-modify-write of the same Hive
key on every block, so the user's own block events could be lost to the race.

`AnalyticsRepositoryImpl.logBlock` additionally serialises appends through a
future chain, which is what actually makes concurrent writers safe. It
deliberately re-reads rather than caching the list in memory: the repo is a lazy
singleton and "Reset app data" (`LocalStore.clearAll`) wipes the box underneath
it, so a buffer would write the wiped events straight back. Pinned by
`test/analytics_buffer_test.dart`.

### 1.6 Dependency injection

`lib/core/di/injector.dart` registers the repo as a lazy singleton over the
`LocalStore`:

```dart
..registerLazySingleton<AnalyticsRepository>(
  () => AnalyticsRepositoryImpl(sl()),
)
```

The cubit itself is not a singleton — it is created per-view by the
`BlocProvider` in `_withCubit`.

### 1.7 This buffer vs. the Firebase telemetry layer

The block-event buffer above is **local-only and never uploads**. It is *not* the
app's product analytics: Detoxo now also ships a **Firebase telemetry layer**
(Analytics, Crashlytics, Performance) that sends anonymised usage/crash/performance
data off-device — see [19-firebase-telemetry.md](19-firebase-telemetry.md). The two
are independent: this `AnalyticsRepository` records *what was blocked* for the
on-device Activity feed; Firebase records app-usage events and crashes. **FCM push
is still not bundled**; AdMob uses Google **test** IDs only (see the monetization
doc).

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
| Local block-event history (rolling ~500, buffer key `analytics_events`) | Shipped |
| Activity feed UI (tab + drawer route) | Shipped |
| Foreground-service notification (`detoxo_protection_channel`, id `1125`, special-use FGS) | Shipped |
| Protection watchdog (`WatchdogJobService`, job `1126`; "Protection stopped" notification `1127` on `detoxo_watchdog_channel`) | Shipped — detect + notify only (a rebind cannot be forced) |
| BootReceiver (schedules the watchdog; OS auto-rebinds the accessibility service) | Shipped |
| App-resume re-sync (`AppResumeSync`: cheap refresh every resume, blocklist/config re-push ≥ 15 min) | Shipped |
| Device Admin uninstall protection + `lockNow()` for `LOCK_SCREEN` | Shipped, optional/opt-in |
| Firebase Analytics / Crashlytics / Performance (off-device telemetry) | **Shipped** — see [19-firebase-telemetry.md](19-firebase-telemetry.md) |
| FCM push | **Not bundled** |
| Cloud sink for the local `AnalyticsRepository` buffer | **Not wired** — the buffer stays on-device |
| Notification suppression (`DetoxoNotificationListener` cancels notifications from apps blocked right now) | Shipped, optional/opt-in and **off by default** — see [29](29-notification-suppression.md). The only notification surface Detoxo *consumes* rather than posts; it unbinds itself whenever it connects with the toggle off, reads a notification's package name, key, user and category only, lets messages and calls through (EVO-038), and never touches Detoxo's own `1125` / `1127` notifications. |
| `LOCK_SCREEN` block mode UI | Retained on the wire, removed from the picker |

---

## Source files

- `lib/features/analytics/analytics.dart`
- `lib/features/analytics/domain/repositories/analytics_repository.dart`
- `lib/features/analytics/data/repositories/analytics_repository_impl.dart`
- `lib/features/analytics/presentation/analytics_cubit.dart`
- `lib/features/analytics/presentation/analytics_screen.dart`
- `lib/features/blocking/shared/domain/entities/engine_event.dart`
- `lib/features/blocking/shared/domain/entities/enums.dart`
- `lib/features/blocking/shared/domain/repositories/blocking_repositories.dart`
- `lib/features/blocking/shared/data/repositories/engine_repository_impl.dart`
- `lib/core/storage/local_store.dart`
- `lib/core/di/injector.dart`
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
