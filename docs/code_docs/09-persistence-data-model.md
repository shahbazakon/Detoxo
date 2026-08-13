# Persistence & Data Model

Detoxo keeps **all** state on-device. There is no live backend, no database
server, and no cross-process ContentProvider. Persistence splits into three
cleanly separated stores, each owned by exactly one side of the platform
boundary:

| Store | Layer | Backing tech | What lives here |
|-------|-------|--------------|-----------------|
| `LocalStore` (`detoxo` box) | Dart | Hive `Box<String>` | User-facing config: settings, blocklists, daily limit, analytics buffer |
| `flutter_secure_storage` | Dart | Keystore / EncryptedSharedPreferences | Secrets only (the PIN config) |
| `detoxo_engine_prefs` | Native (Kotlin) | `SharedPreferences` | The engine's own runtime state: pushed config, plan, counters, Conscious bank |
| `home_widget` data + native store | Bridge | `home_widget` plugin + `detoxo_engine_prefs` | Home-screen widget face (`cc_today` / `cc_total`) |

> **Not used (from the old blueprint):** Room, drift/SQLite, any
> `ContentProvider`, and any multi-process `SharedPreferences`
> (`MODE_MULTI_PROCESS`). The engine runs in the **main process**, so ordinary
> private `SharedPreferences` are sufficient; there is no `:as_process` to
> synchronise with. No cloud/remote sync of the local **stores** is bundled — the separate
> Firebase telemetry layer ([19-firebase-telemetry.md](19-firebase-telemetry.md)) sends anonymised
> usage/crash data but is not a data store and does not sync these files.

The Dart and native stores are **independent files** with **independent
lifecycles**. They are not mirrors of each other; Dart _pushes_ a curated
subset of its state into the engine store over the command channel (see
[04-native-android-layer.md](04-native-android-layer.md)), and the engine
_emits_ counters back over the event channel that Dart then persists in its own
store.

---

## 1. Dart: `LocalStore`

`lib/core/storage/local_store.dart` is the single seam for all Dart-side
persistence. It is a thin wrapper exposing a plain **key → string** API, so
repositories stay trivially simple and never touch Hive or the secure plugin
directly.

```dart
class LocalStore {
  final Box<String> _box;            // Hive box named 'detoxo'
  final FlutterSecureStorage _secure; // secrets

  static Future<LocalStore> create() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('detoxo');
    return LocalStore._(box, const FlutterSecureStorage());
  }

  // Plain (non-secret) values — synchronous read, async write.
  String? read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  // Secret values — always async (crosses the plugin channel).
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String value);
  Future<void> deleteSecret(String key);

  Future<void> clearAll();           // wipes the box AND every secret
}
```

Key facts:

- **Backing store is Hive** (`hive` / `hive_flutter`), opened as a
  `Box<String>` named `detoxo`. Values are always JSON strings that the owning
  repository encodes/decodes; the box itself is untyped beyond `String`. (Hive
  _is_ used here — only Room/drift/ContentProvider are the abandoned
  blueprint choices.)
- **Secrets go through `flutter_secure_storage`**, a physically separate store
  keyed independently of the Hive box.
- **Plain reads are synchronous** (`read` returns `String?` immediately from the
  in-memory box); writes/deletes are async. Secret ops are always async.
- Registered once as a **`get_it` singleton** in
  `lib/core/di/injector.dart` (`configureDependencies` awaits
  `LocalStore.create()` before anything else, then
  `sl.registerSingleton<LocalStore>(store)`). Every repository takes it by
  constructor injection.

### 1.1 `StoreKeys` — the Dart data model

All keys are declared as `StoreKeys` constants (bottom of `local_store.dart`).
Each key maps to exactly one repository that owns its JSON shape:

| `StoreKeys` constant | Key string | Secret? | Owner repository | Persisted value shape |
|---|---|---|---|---|
| `settings` | `app_settings` | no | `SettingsRepositoryImpl` | `AppSettings.toJson()` — one JSON object |
| `pinConfig` | `pin_config` | **yes** | `PinRepositoryImpl` | `PinConfig.toJson()` (hashed secret + salt) |
| `webBlocklist` | `web_blocklist` | no | `WebBlockRepositoryImpl` | JSON list of blocklist entries |
| `webBlockStats` | `web_block_stats` | no | `WebBlockStatsRepositoryImpl` | `{date, today, total, hosts:{host:count}}` |
| `appBlocklist` | `app_blocklist` | no | `AppBlockRepositoryImpl` | JSON list of `AppBlockEntry.toJson()` |
| `protectedApps` | `protected_apps` | no | `ProtectedAppsRepositoryImpl` | JSON list of `ProtectedApp.toJson()` |
| `dailyLimit` | `daily_limit` | no | `DailyLimitRepositoryImpl` | `DailyLimit.toJson()` — one JSON object |
| `streak` | `daily_limit_streak` | no | `StreakRepositoryImpl` | `Streak.toJson()` — `{base, lastDay, todayFailed}` |
| `analyticsEvents` | `analytics_events` | no | `AnalyticsRepositoryImpl` | JSON list of block events (capped) |
| `premiumDevUnlock` | `premium_dev_unlock` | no | *(reserved — no live consumer)* | — |
| `dismissedNotices` | `dismissed_notices` | no | *(reserved — no live consumer)* | — |

> **Reserved keys.** `premium_dev_unlock` and `dismissed_notices` are declared
> in `StoreKeys` but currently have **no reader or writer** anywhere in
> `lib/`. There is no `lib/features/monetization` tree in the shipped source, so
> the premium dev-unlock is modeled/planned rather than wired — treat these two
> keys as **reserved / follow-up**, not live state. (See
> [11-monetization.md](11-monetization.md) for the premium entitlement model.)

### 1.2 Per-key value shapes

- **`app_settings`** — the whole `AppSettings` entity as a single JSON object
  (`activePlan`, `baseMode` [the sticky base plan an override reverts to — wire key
  `baseMode`, only ever `BLOCK_ALL`/`CURIOUS`; `fromJson` collapses anything else,
  incl. an override plan or legacy `paused`, to Block All], `defaultBlockMode`,
  `enabledPlatformIds`, `reelAllowance` [the One Reel / Unblock target, 1..20,
  defaulting to 1 via `(json['reelAllowance'] as num?)?.toInt() ?? 1`], pause session,
  theme, website toggles, …). This `baseMode` is a **Dart-only** persistence field —
  it is not pushed on the native wire (native only ever sees the derived `activePlan`).
  `SettingsRepositoryImpl` caches it in memory (`_cache`) after first
  load and re-broadcasts on every `save` through a broadcast `StreamController`, so
  Cubits watching settings update live without re-reading Hive.
- **`pin_config`** (secret) — `PinConfig.toJson()`: PIN `type`, `secretHash`,
  `salt`, `secretLength`. `PinRepositoryImpl.load()` also performs a **one-time
  migration**: legacy installs that stored a plaintext `secret` are re-hashed
  (salt + `PinHasher.hash`) and the plaintext is dropped, then persisted back so
  it never sits unhashed again. See [08-pin-lock-recovery.md](08-pin-lock-recovery.md).
- **`web_blocklist`** — JSON list of website patterns (`{pattern, matchType}`
  wildcard entries). This is the source list; it is pushed to the engine via
  `pushWebBlocklist`, which stores its own copy in `detoxo_engine_prefs`
  (`web_blocklist_json`). See [06-app-and-web-blocker.md](06-app-and-web-blocker.md).
- **`web_block_stats`** — `{ "date": "yyyy-MM-dd", "today": int, "total": int,
  "hosts": { host: count } }`. `WebBlockStatsRepositoryImpl` treats the **native
  engine as the source of truth** for `today`/`total` (they survive the UI being
  killed) — it copies the `today`/`total` off each `webBlocked` event and only
  falls back to a local increment if the event omitted them. The per-host
  `hosts` map is Dart-only, so the dashboard can surface the most-blocked site.
  `today` rolls over on a new calendar day (`_rollDate`).
- **`app_blocklist`** — JSON list of `AppBlockEntry` (full-app blocks, distinct
  from reel-platform detection).
- **`protected_apps`** — JSON list of `ProtectedApp`
  (`{packageName, appName, category, isEnabled, source}`) holding the user's
  **manual additions only**. Catalog apps (banks, UPI, password managers…) are
  protected implicitly and never stored; `load()` filters out legacy
  `source: catalog` rows that early builds seeded, and treats absent/unreadable
  data as `[]` (nothing is lost — the catalog is derived). The native push is
  always `catalog ∪ enabled manual` (`pushProtectedApps` →
  `protected_packages` below). See [24-protected-apps.md](24-protected-apps.md).
- **`daily_limit`** — `DailyLimit.toJson()`; defaults to `const DailyLimit()`
  when absent. See [07-daily-limit-scheduler.md](07-daily-limit-scheduler.md).
- **`daily_limit_streak`** — `Streak.toJson()` (`{base, lastDay, todayFailed}`);
  the "days under your daily limit" streak surfaced on the dashboard hero.
  Defaults to `const Streak()` when absent. Owned by `StreakRepositoryImpl`,
  advanced once per day by `StreakCubit`. See
  [07-daily-limit-scheduler.md](07-daily-limit-scheduler.md).
- **`analytics_events`** — a capped JSON list of block events, newest-first.
  `AnalyticsRepositoryImpl` prepends each new event and truncates to
  **`_maxEvents = 500`**. Each event serialises as
  `{platformId, packageName, mode, ts}` where `ts` is epoch millis. This is a
  **local buffer only** — the class comment notes a cloud sink (Firebase
  Analytics) "can be added behind the same interface later"; none is bundled.
  See [12-analytics-notifications-resilience.md](12-analytics-notifications-resilience.md).

### 1.3 Wiping Dart data ("Reset app data")

`LocalStore.clearAll()` clears the Hive box **and** deletes every secret
(`_secure.deleteAll()`). It is invoked from
`lib/features/settings/presentation/settings_screen.dart` (`sl<LocalStore>().clearAll()`)
behind the "Reset app data" action; the app then re-bootstraps from defaults.

> **Scope of the wipe.** `clearAll()` only touches the **Dart** stores. It does
> **not** clear the native `detoxo_engine_prefs` file — the engine's plan,
> counters and Conscious bank persist across a Dart-side reset until Dart pushes
> fresh config/settings into them.

---

## 2. Native: `detoxo_engine_prefs`

A single private `SharedPreferences` file, **`detoxo_engine_prefs`**
(`Context.MODE_PRIVATE`), shared by two owner classes so the
`AccessibilityService`, the `CommandHandler`, the overlay bubble and the
home-screen widget all read one source of truth:

- `engine/ConfigStore.kt` — engine configuration, active plan, block counters,
  website-blocking flags, and the Conscious token bucket.
- `engine/ContentCounterStore.kt` — the decoupled reel/short **counter** state
  (counts, per-app maps, bubble position, appearance).

Both open the file by the same constant `PREFS = "detoxo_engine_prefs"`. Because
the service runs in the **main process**, no multi-process mode is needed.

### 2.1 `ConfigStore` keys

Written by Dart via `CommandHandler` (`pushConfig`, `pushSettings`,
`pushWebBlocklist`, `pushProtectedApps`); read by `DetoxoAccessibilityService`.

| Key string | Type | Default | Meaning |
|---|---|---|---|
| `platforms_config_json` | String? | null | The Dart-pushed `platforms_config.json` the detector parses |
| `active_plan` | String | `BLOCK_ALL` | Plan **wire token**: `BLOCK_ALL`, `CURIOUS` (= *Conscious* in the UI), `ONE_REEL`, `PAUSED` |
| `default_block_mode` | String | `PRESS_BACK` | `PRESS_BACK` / `KILL_APP` / `LOCK_SCREEN` / `NONE` |
| `enabled_platforms` | Set<String> | ∅ | Enabled `platformId`s (e.g. `ig_reel`, `yt_shorts`) |
| `protected_packages` | Set<String> | ∅ | Privacy-protected package names the service ignores entirely (survives reboot with Flutter dead) |
| `vibration_enabled` | Boolean | true | Vibrate on block |
| `master_enabled` | Boolean | true | Global on/off for blocking |
| `pause_until` | Long | 0 | Epoch millis until which blocking is paused (0 = not paused) |
| `web_blocklist_json` | String? | null | Active website blocklist `[{pattern,matchType}]` |
| `block_adult_websites` | Boolean | false | Enforce the bundled adult-domain set |
| `block_websites_for_blocked_apps` | Boolean | false | Enforce websites of blocked apps |

> The stored `active_plan` is the **wire token**, not the UI label. The constant
> `CommandHandler.PLAN_CONSCIOUS = "CURIOUS"` — i.e. the Conscious plan is
> persisted verbatim as `"CURIOUS"`. Do not rename it. See
> [05-plans-pause-conscious.md](05-plans-pause-conscious.md).

**Reel block counters** (`recordBlock` / `blockStats`):

| Key | Type | Meaning |
|---|---|---|
| `block_date` | String | Last-recorded day key (`dd-MM-yyyy`) |
| `block_today` | Int | Blocks recorded today (durably reset on rollover) |
| `block_total` | Int | All-time block count |

`recordBlock(dateKey)` compares the stored day to `dateKey`; on a mismatch it
resets today's count to 0 **and writes** the new date in the same edit, then
increments today + total. `blockStats()` returns `(today, total, date)`.

**Website block counters** (`recordWebBlock` / `webBlockStats`) — kept separate
from the reel counter:

| Key | Type | Meaning |
|---|---|---|
| `web_block_date` | String | Last-recorded day key |
| `web_block_today` | Int | Website blocks today |
| `web_block_total` | Int | All-time website blocks |

**Conscious token bucket** — the engine owns this balance so it keeps ticking
even when the Flutter UI is dead:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `conscious_bank_ms` | Long | 0 | Banked allowance, millis (0..max) |
| `conscious_anchor_ms` | Long | 0 | Wall-clock anchor for the last accounting tick |
| `conscious_earn_divisor` | Int | 10 (min 1) | Earn rate: `bank += elapsed / divisor` while abstaining |
| `conscious_max_bank_ms` | Long | 600000 (10 min) | Cap on banked allowance |

`resetConsciousBank(now)` empties the bank and re-anchors to `now`. Switching
_into_ the Conscious plan from `pushConfig` triggers a reset. The bank drains
1:1 while a reel is on screen and refills at `1/divisor` while abstaining, capped
at `conscious_max_bank_ms`. See [05-plans-pause-conscious.md](05-plans-pause-conscious.md).

**One Reel / Unblock session** — the `oneReel` plan grants a fixed allowance of
reels, then re-blocks. The engine owns the running count so it keeps enforcing when
the Flutter UI is dead:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `reel_allowance` | Int | 1 | Reels allowed before re-block, coerced to **1..20** (`= 1` One Reel, `2..20` Unblock N). Pushed via `pushSettings` and (re)set by `armReelSession`. |
| `reels_consumed` | Int | 0 | Distinct reels consumed this session (0..allowance). **Persisted** — an OS-driven service restart keeps the user blocked until an explicit re-tap. |

`resetReelSession()` zeroes `reels_consumed`. It is called **only** by the imperative
`armReelSession` command (a fresh mode tap); a plain `pushSettings` never resets the
count, so an unrelated settings change can't refill a spent session. See
[05-plans-pause-conscious.md](05-plans-pause-conscious.md) §7.

### 2.2 `ContentCounterStore` keys

The counter is **decoupled from blocking** and enabled by default. Written by
`engine/ContentCounter.kt` (`recordCount`) and by `CommandHandler`
(`setContentCounterEnabled`, `setContentBubbleEnabled`, `setCounterStyle`); read
by the bubble overlay and the widget provider.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `cc_enabled` | Boolean | **true** | Master on/off for counting (awareness on by default) |
| `cc_bubble_enabled` | Boolean | true | Whether the floating bubble may be shown |
| `cc_bubble_x` | Int | −1 | Last bubble X px (−1 = unset → snaps to default edge) |
| `cc_bubble_y` | Int | −1 | Last bubble Y px (−1 = unset → default top offset) |
| `cc_date` | String | "" | Day key of the current `today` bucket (`dd-MM-yyyy`); the **single** rollover marker shared by the reel counts **and** the usage-time buckets below |
| `cc_today` | Int | 0 | Reels counted today |
| `cc_total` | Int | 0 | All-time reel count |
| `cc_time_today` | Long | 0 | Whole-app foreground time (ms) in monitored social apps today — drives the dashboard screen-time ring + bubble tap-to-reveal |
| `cc_time_total` | Long | 0 | All-time whole-app foreground time (ms) |
| `cc_per_app_today` | String (JSON) | `{}` | `{pkg: count}` for today |
| `cc_per_app_total` | String (JSON) | `{}` | `{pkg: count}` all-time |
| `cc_bubble_style` | String (JSON) | "" | Bubble appearance (Dart `BubbleStyle.toWire`) |
| `cc_widget_style` | String (JSON) | "" | Widget appearance (Dart `WidgetStyle.toWire`) |

**Counting** (`recordCount(pkg, dateKey)`): on a stored-date mismatch it resets
the today total and `cc_per_app_today` to 0/`{}` **and zeroes `cc_time_today`**
(**durable** midnight rollover), then increments the today + total scalars and
both per-app maps in a single `edit()`.

**Usage time** (`recordUsage(deltaMs, dateKey)`): adds `deltaMs` of monitored-app
foreground time to `cc_time_today` + `cc_time_total`. It shares the same `cc_date`
marker, so on a stored-date mismatch it symmetrically zeroes `cc_today` and
`cc_per_app_today` before adding. **Shared-rollover invariant:** because one
`cc_date` gates both features, whichever writer turns the day over must zero the
*other* feature's today bucket too — otherwise a same-day read after that write
would return yesterday's value. `timeTodayMs(dateKey)` is a cheap bubble-side read
that returns 0 on a stale date. (Where the deltas come from — the event-gap
heuristic in `ContentCounter.onAppActivity` — is in
[17-content-counter.md](17-content-counter.md) §2.6.)

**Snapshot rollover nuance** (`snapshot(dateKey)`): the snapshot applies a
**read-time** rollover — when the stored day is stale, `today`, `perAppToday` and
`timeTodayMs` read as **0 without writing**; the next `recordCount`/`recordUsage`
performs the durable reset. So a snapshot pulled just after midnight is correct
even before the day's first event. The snapshot map is what feeds the
`contentCounterSnapshot` command, the widget render, and the Dart Cubit's
hydration; it also carries `timeTotalMs` and `bubbleStyle` / `widgetStyle`.
`todayCount(dateKey)` is a cheap path for the bubble that likewise returns 0 on a
stale date.

See [content counter docs] for the Dart side
(`lib/features/content_counter/...`) and the bubble/widget renderers in
`android/.../overlay/` and `android/.../widget/`.

### 2.3 Date-key formats (be careful)

The stores use **different** date-key formats — each is internally consistent
but they are not interchangeable:

| Producer | Format | Example |
|---|---|---|
| Native `ConfigStore` / `ContentCounterStore` / widget / `CommandHandler.dateKey()` | `dd-MM-yyyy` | `03-07-2026` |
| Dart `WebBlockStatsRepositoryImpl._todayKey()` | `yyyy-MM-dd` | `2026-07-03` |
| Dart analytics events | epoch millis (`ts`) | `1751500800000` |

---

## 3. Home-screen widget bridge (`cc_today` / `cc_total`)

`home_content_counter/data/repositories/home_widget_repository_impl.dart` drives
the 2×2 home-screen widget through the `home_widget` plugin. The important
design point: **the native `ContentCounterStore` is the real source of truth** —
the widget provider (`widget/ContentCounterWidgetProvider.kt`) renders its face
from `ContentCounterStore(context).snapshot(...)`, so it stays correct even when
the Flutter UI is dead.

- `pushSnapshot(count)` writes `cc_today` and `cc_total` via
  `HomeWidget.saveWidgetData<int>(...)` **and** calls
  `_channel.refreshContentWidget()`. The `home_widget` write is a best-effort
  convenience mirror; if the plugin is unavailable the `catch` swallows it and
  the native render is still authoritative.
- `pin()` calls `HomeWidget.requestPinWidget(...)` and falls back to the native
  `pinContentWidget()` command if the launcher refuses or the plugin is
  unavailable.
- All widget calls are gated by `PlatformCapabilities.supportsBlockingEngine`
  (Android-only); on unsupported platforms `pin()` returns `false` and
  `pushSnapshot`/`refresh` no-op.

So there are **two `cc_today`/`cc_total` copies**: the `home_widget` plugin's own
data store (written by Dart, a convenience mirror) and the authoritative
`detoxo_engine_prefs` integers written by the native counter. The provider only
reads the latter; the native counter also calls `pushUpdate` directly on each
counted reel (throttled) so the widget refreshes without any Dart round-trip.

---

## 4. What is deliberately absent

| Not present | Note |
|---|---|
| Room / SQLite / drift | No relational DB anywhere. All Dart state is JSON-in-Hive; all native state is `SharedPreferences`. |
| `ContentProvider` | No content provider is exported or used to share state across processes. |
| Multi-process prefs | `detoxo_engine_prefs` is opened `MODE_PRIVATE`; the service runs in the main process, so no `MODE_MULTI_PROCESS` and no `:as_process`. |
| Remote / cloud sync of local data | No backend syncs the local stores; the block-event buffer stays on-device (no cloud sink). A separate Firebase **telemetry** layer sends anonymised usage/crash/perf data — see [19-firebase-telemetry.md](19-firebase-telemetry.md). |
| Live premium storage | `premium_dev_unlock` is a reserved `StoreKeys` constant with no live consumer; premium is modeled/planned. |

---

## Source files

- `lib/core/storage/local_store.dart`
- `lib/core/di/injector.dart`
- `lib/features/blocking/shared/data/repositories/settings_repository_impl.dart`
- `lib/features/access_protection/data/repositories/pin_repository_impl.dart`
- `lib/features/limits/web_blocker/data/repositories/web_block_stats_repository_impl.dart`
- `lib/features/limits/web_blocker/data/repositories/web_block_repository_impl.dart`
- `lib/features/limits/app_blocker/data/repositories/app_block_repository_impl.dart`
- `lib/features/protected_apps/data/repositories/protected_apps_repository_impl.dart`
- `lib/features/limits/daily_limit/data/repositories/daily_limit_repository_impl.dart`
- `lib/features/limits/streak/data/repositories/streak_repository_impl.dart`
- `lib/features/analytics/data/repositories/analytics_repository_impl.dart`
- `lib/features/settings/presentation/settings_screen.dart`
- `lib/features/content_counter/home_content_counter/data/repositories/home_widget_repository_impl.dart`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounterStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/widget/ContentCounterWidgetProvider.kt`
