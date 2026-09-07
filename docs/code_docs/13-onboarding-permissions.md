# Onboarding & Permission Funnel

How a first-run Detoxo user gets from cold launch to a working blocker: the persisted onboarding step machine, the guided runtime-permission funnel, and the single router `redirect` that decides which of those (if any) to show.

Gating is **declarative**: one `redirect` on the `GoRouter`, reading `AppGate`. It is no longer performed imperatively from the splash screen. See [01-overview-architecture.md](01-overview-architecture.md) §3–§4 for the gate itself; this doc covers what onboarding *produces*.

---

## 1. The gate (source of truth)

`lib/app/splash_screen.dart` renders the brand moment and calls `runBootstrap(context)` (`lib/app/bootstrap.dart`). It does **not** route. The bootstrap hydrates settings / permissions / PIN, seeds the enabled-platform set on a first run, then opens `AppGate` — and the router's `redirect` takes it from there, in this order:

| # | Condition | Route | Notes |
|---|-----------|-------|-------|
| 0 | `!ready` | `Routes.splash` (`/`) | Bootstrap unfinished; nothing routes on unloaded state |
| 1 | `!supported` | `Routes.unsupported` (`/unsupported`) | `PlatformCapabilities.isBlockingPreviewOnly` — iOS / web |
| 2 | `!onboarded` | `Routes.onboarding` (`/onboarding`) | Hasn't finished the first run |
| 3 | `pinLocked` | `Routes.pinLock` (`/pin/lock`) | An **app-scope** PIN is set |
| 4 | `!permissionsOk` | `Routes.permissions` (`/permissions`) | Missing a required permission |
| 5 | (else) | `Routes.home` (`/home`) | Fully set up |

So the canonical funnel is **onboarding → PIN lock → permissions → home**. The first failing condition wins.

Notes on the gate:

- **`onboarded`** is a boolean on `AppSettings` (`lib/features/blocking/shared/domain/entities/app_settings.dart`), persisted through the settings store. It is deliberately **not** the onboarding progress record (§2.2) — an install that predates that record must never be re-onboarded just because the record is absent.
- **PIN gate** uses `PinConfig.isConfigured` (`type != PinType.none`) **and** `guards(PinScope.app)` — i.e. only a PIN whose `scopes` set contains `PinScope.app` (wire `DETOXO_APP`) blocks the launch. A PIN scoped only to settings/plan-switch/etc. does **not** gate the launch. On a genuine first run no PIN exists, so this stage is skipped. (PIN mechanics — types, salted hashing, lockout ladder, biometrics, recovery — live in the access-protection docs; the gate only reads `PinCubit` state at bootstrap.)
- **Required-permission gate** uses `PermissionsCubit.allRequiredGranted` (see §3), pushed into the gate by a `BlocListener` in `main.dart` so a grant or a revocation re-routes on its own. It applies **only** from a pass-through screen or `/home` (`AppGate._permissionsGateApplies`): the cubit re-emits on every app resume, so an unscoped gate would yank a user off `/rules/edit` mid-edit and destroy their unsaved rule along with its `state.extra`. They are funnelled the next time they pass through home (EVO-041).
- `/permissions` is a **destination, not a pass-through**: once the required permissions are granted the redirect leaves the user on it, so granting accessibility and overlay does not yank them off the screen while they work through the recommended ones.

---

## 2. Onboarding (`onboarding` feature)

`lib/features/onboarding/` is a full slice (`domain/`, `data/`, `presentation/`). Its barrel exports the screen plus the domain that outlives it — the progress record and the survey→rule mapping, both read by `lib/app/starter_rule_sync.dart`.

The old five-page `PageView` intro captured exactly one value (the daily-limit dial) and **persisted no position** — killing the app on page 4 restarted it at page 1. It also ended with a daily limit and nothing else: no rule, no reason. It has been replaced by a linear, persisted step machine that ends with a working rule in place.

### 2.1 The three properties that carry the design

1. **Persist before navigating.** The whole machine lives inside the *one* `/onboarding` route, so "navigate" is an `emit` — `await save` then `emit` gets the ordering for free, with no partial route stack to rebuild. A crash between the two resumes at the *next* step, a harmless replay; the reverse order loses it. Pinned by `test/onboarding_resume_test.dart`, which holds the write open and inspects both sides mid-flight.
2. **Write each answer as it is given**, never batched. Batching at the end means a user who abandons at the last question is a user whose answers never existed.
3. **Create the starter rule at grant time, not at selection time** (§2.4). A rule written when the feeds are picked does nothing for however long the user hesitates on the accessibility screen — and nothing forever if they never grant it.

### 2.2 Steps and storage

Six walked steps, `OnboardingStepId` (stable wire tokens), plus a terminal `completed`:

| Step | Purpose |
|---|---|
| `welcome` | What Detoxo is, in one screen (`CaughtHero` + "Blocks the reels, not the app") |
| `survey` | Name (optional), screen-time band, what matters most |
| `projection` | The five-year cost, computed from the band |
| `selection` | Pick the feeds to protect — **requires ≥ 1** |
| `commitment` | The promise, keyed to `mattersMost`, plus the daily-limit dial |
| `permissions` | Hands off to the real `/permissions` screen — the hard gate |

Persisted under `StoreKeys.onboardingProgress` (`'onboarding_progress'`) by `OnboardingRepositoryImpl`, as JSON with enums as **stable name strings**:

```jsonc
{
  "step": "SURVEY",
  "name": null,
  "screenTimeBand": "BETWEEN_3_AND_4H",
  "mattersMost": "FOCUS",
  "selection": { "platforms": ["ig_reel"] },
  "dailyLimitMinutes": 90,
  "startedAtMs": 1756742400000
}
```

Reads are tolerant in the `Rule` / `AppSettings` idiom (hand-rolled JSON, not freezed): an unknown enum token degrades to `null`, an unknown step to `welcome`, and a corrupt or unparseable blob restarts the run rather than stranding the launch on a crash it cannot escape. `dailyLimitMinutes` is **clamped** to the dial's own 15 min – 5 h range on read: the widget is the only bound in the UI, so a restored or hand-edited record could otherwise hand `setLimit` a `0`, which `DailyLimit.isExceeded` treats as "no limit at all" — silently switching the ceiling off while the screen still showed one.

**The record holds PII.** A first name, a self-reported screen-time band and the list of social feeds the user has. The Hive box is excluded from Google cloud backup and device-to-device transfer (`android:allowBackup="false"` plus `res/xml/data_extraction_rules.xml`, EVO-005); it is cleared the moment the starter rule lands.

Vocabularies: `ScreenTimeBand` — 7 bands plus `DONT_KNOW`, each carrying an `hoursPerDay` midpoint (the projection's only input; `DONT_KNOW` uses the average, because a zero projection would reward not answering). `MattersMost` — `FOCUS SLEEP PRESENT MENTAL OTHER`.

### 2.3 Script as data

`domain/onboarding_script.dart` holds `surveyQuestions`, a `List<OnboardingQuestion>` of `(field, prompt, kind, options, optional)`. The survey step walks the list and renders it, so **adding a question is a list edit** — no new widget, no new state field, no new navigation edge. `SurveyStep.isComplete` is derived from the same list, so a new required question gates the step with no other change.

The table is deliberately **non-generic**: a `const` list of `AskChips<SomeEnum>` erases to `dynamic` in the walker anyway, so the type parameter would buy nothing and cost a cast at every render. The table covers the survey only — `projection` needs arithmetic, `selection` needs `TargetsCubit`, and `permissions` is an existing screen.

### 2.4 The starter rule

`domain/starter_rule.dart` maps the survey to **one** M3 rule, built from the existing `RulePreset` set rather than from scratch — M3 already ships these windows, and a second copy of "22:00–07:00" is a second thing to keep right:

| `mattersMost` | Rule |
|---|---|
| `SLEEP` | `RulePreset.sleep` — schedule, daily 22:00–07:00 (exercises the overnight-wrap path) |
| `FOCUS` | `RulePreset.workHours` — schedule, Mon–Fri 09:00–17:00 |
| `PRESENT` / `MENTAL` / `OTHER` / **skipped** | `RulePreset.doomscrollBudget` — time limit, 30 min/day, `lockPeriod: END_OF_DAY` |

`mattersMost` is **nullable and null is a real answer**: skipping the survey used to leave it null, which the commitment screen rendered as the 30-minute budget while the sync refused to write anything — the app stating a behaviour it did not implement, on the last screen before the grant. `starterPreset(null)` now returns the preset that copy describes (EVO-039), and the commitment screen renders its promise **from that preset** rather than restating the hours in prose, so the two cannot drift.

The preset's *category* selection is replaced with the `platformId`s the user actually picked: a starter rule must block what they chose, not a default taxonomy. `lockPeriod` needs no field — `Rule.toJson` already emits `END_OF_DAY` as the only time-limit lock behaviour M3 shipped. The presets are reached by **name** (`RulePreset.sleep`, not `RulePreset.all[1]`) so reordering the empty-state list cannot silently change which rule a new user gets. Covered by `test/starter_rule_test.dart`.

**When it is written.** `lib/app/starter_rule_sync.dart` is mounted app-wide in `main.dart` beside `AppResumeSync`. There is **no push event for "accessibility granted"** — the state is read, not delivered — but `AppResumeSync` already refreshes permissions on every resume and the cubit re-polls itself 400 ms after a request, so the signal arrives on its own whether the user returns to the app or grants while it is still foregrounded.

It reads a **level, not an edge**, and that distinction is load-bearing. Watching the false→true edge on `allRequiredGranted` is the obvious design and it was silently broken: `PermissionsCubit.effectivelyGranted` consults `_lastKnownGranted`, which `refresh()` overwrites *before* it emits, so re-evaluating the PREVIOUS state inside `listenWhen` scored it against post-refresh memory. A previous emit holding a live `unknown` for an already-persisted permission read back as granted, `!true` collapsed the edge, and the rule was never written — on the most ordinary path there is, because the 400 ms poll after `request()` routinely returns `unknown`. The write is idempotent, so firing on every emit costs nothing and cannot go wrong that way.

Two listeners, not one. The second watches `RulesState.loaded`, because the grant can be discovered by the bootstrap's own `permissions.refresh()` while `RulesCubit` is still loading — and `RulesCubit.save` refuses to write on top of rules it has not read. Waiting for `loaded` keeps `rules.load` off the startup critical path.

The decision itself lives in `applyStarterRule`, a top-level function taking the repository, a `save` callback and an `isMounted` probe — so the branches below are covered by plain unit tests (`test/starter_rule_sync_test.dart`) with no widget tree:

| Record | Action |
|---|---|
| `step: permissions` | Write the rule, then clear the record |
| `step: completed` | Clear it — an orphan from a crash between marking completed and clearing |
| anything else | Nothing: an existing install (no record ⇒ `welcome`) or a run still in progress |

So **no upgrading user ever gets a rule they did not ask for**. Two paths deliberately leave the record ARMED rather than consuming it: a refused `save` (the rule cap, or a rules blob that never loaded) and an unmounted teardown mid-await — both mean "try again later", not "job done". The rejected-save path logs through `AppLogger.e`, not `.w`, because `.w` is debug-only and this is the one outcome the whole funnel exists to prevent: granted, onboarded, and no rule.

### 2.5 The walker and its chrome

`presentation/onboarding_screen.dart` provides `OnboardingCubit` for the `/onboarding` route only (cubits are never registered in `sl` in this repo; the *repository* is) and renders whatever step the cubit is on through an `AnimatedSwitcher`. Existing chrome is kept verbatim: the segmented `_ProgressBar` (`Semantics(label: 'Step N of M')`), the top-left **Back** and top-right **Skip** ghost buttons, and the accent-tinted full-width `PrimaryButton`.

- **Next** is gated only where it must be: `survey` needs its required answers, `selection` needs ≥ 1 feed — *unless there is nothing to pick*. A device with none of the supported apps installed would otherwise be a permanent dead end: Next disabled, Skip already gone, so onboarding could never be completed and `onboarded` never flipped, returning the user to the same screen on every future launch.
- **`permissions` is terminal for the walker.** Reaching it — or resuming onto it after a crash between `advance` and `setOnboarded` — re-runs the hand-off. Without that the resumed state rendered an enabled button that did nothing, on a screen the user could not tell they had already passed.
- **Skip** jumps to `selection` and disappears from there on — neither the picks nor the permissions are skippable, because without them onboarding has protected nothing.
- **Back** walks the machine backwards and never erases an answer. A `PopScope` routes the system back button through the same path, so it cannot drop the user out of the app mid-onboarding.
- The **selection** step renders through the blocklist's own `BlockAppGroup` / `BlockAppTile`, so Instagram's Feed / Reels / Stories collapse under one tile exactly as they do on the blocklist screen and the two cannot drift. Only installed apps are listed — offering feeds the user cannot open would make the "pick at least one" gate answerable with something that blocks nothing.
- The **commitment** step keeps the interactive `ScreenTimeDial` (270° radial gauge, **15 min – 5 h**, **15-minute** steps, default **90 min**) that used to be page 3, and its promise copy is keyed to the same `mattersMost` answer that picks the starter rule — so what the user reads is what the rule will actually do.
- All motion is guarded by `MediaQuery.maybeDisableAnimationsOf` and degrades to a static end-state under reduce-motion. Heroes remain coded illustrations built from design-system primitives — no Lottie or illustration assets.
- A funnel event (`AnalyticsEvent.onboardingStep`) fires per step change with `step` and `direction` (`ENTER` / `FORWARD` / `BACK`). Only those two tokens are sent — never a name, a band or a picked feed. `ENTER` fires from `load()`, so the first step has a denominator; the direction separates a Back tap from a Next tap, which are the same `advance` call and would otherwise inflate every step total (EVO-040).

### 2.6 Finishing

Leaving `commitment` advances the record to `permissions`, writes the dial value through the app-wide `DailyLimitCubit` (so the dashboard ring re-emits live) and flips `onboarded` through **`SettingsCubit.setOnboarded`**. The redirect then routes on to `/permissions` by itself.

`onboarded` flips **here, not at grant time**, on purpose: a user who quits on the permission screen has already answered everything, and making them replay the funnel to get back to a system settings toggle is the worst version of this flow. The record keeps `step: permissions`, which is what still arms the starter rule.

> **The splash round-trip is gone.** The old `_finish()` wrote `onboarded` through the raw `SettingsRepository` and then navigated to `/` rather than `/permissions`, because a raw write left `SettingsCubit.state` stale at `onboarded: false` and the next `_commit` from *any* setter would `copyWith` that stale value straight back over Hive — walking the user through onboarding again on the next cold launch. The whole workaround existed because `tool/check_boundaries.sh` forbade onboarding importing `blocking/shared/presentation/`. Exporting `SettingsCubit` (and `TargetsCubit`, and `BlockAppTile`) from `lib/features/blocking/blocking.dart` — the `content_counter` / `limits` precedent — removed the cause, and **burned `tool/boundaries_baseline.txt` down from seven grandfathered entries to zero**. The general rule still stands for anything else: an `AppSettings` field written behind the cubit's back must be followed by a cubit reload, or it will be silently reverted.

---

## 3. Permission funnel (`permissions` feature)

`lib/features/permissions/` is a full Clean-Architecture slice (domain / data / presentation). Its barrel (`permissions.dart`) exports only the domain entity + repository contract.

### 3.1 Domain model

`domain/entities/permission_status.dart`:

- **`AppPermission`** enum — one entry per permission, carrying a user-facing `label`, the `why` copy, and a `required` flag:

  | Enum | Label | `why` | Required | Gate-able |
  |------|-------|-------|----------|-----------|
  | `accessibility` | "Accessibility" | "Lets Detoxo detect and block reels & shorts." | **yes** | ✓ |
  | `overlay` | "Display over apps" | "Shows the block / PIN screen over other apps." | **yes** | ✓ |
  | `notifications` | "Notifications" | "Alerts you if protection stops." | no | — |
  | `usageAccess` | "Usage access" | "Powers app usage limits." | no | — |
  | `batteryOptimization` | "Unrestricted battery" | "Keeps the blocker alive. Pick Detoxo, then \"Don't optimize\"." | no | — |
  | `deviceAdmin` | "Uninstall protection" | "Optional uninstall protection." | no | ✓ |
  | `notificationListener` | "Notification access" | "Silences notifications from apps you have locked." | no | ✓ |

  `why` lives on the enum because three surfaces render it (funnel, settings sheet, dashboard card) and the previously duplicated copies had already drifted. Icons stay in presentation — an `IconData` field would drag `flutter/material` into a domain layer that otherwise imports only `equatable`.

  **Gate-able** marks `restrictedWhenSideloaded`: the toggles Android's restricted-settings / ECM gate can silently refuse (§3.5).

  Only **accessibility** and **overlay** are required — they are the minimum for the blocker to detect and to draw the block/PIN screen. Everything else is "recommended", so adding `notificationListener` changed the funnel's denominator (now 7) without affecting `allRequiredGranted` or the splash gate.

- **`PermissionStatus`** (`Equatable`) — `{ kind, state }` with `granted`, `permanentlyDenied`, and `blockedByRestrictedSettings` (`permanentlyDenied && kind.restrictedWhenSideloaded`) getters, plus `copyWith`.
- **`PermissionState`** (defined in `lib/features/blocking/shared/domain/entities/enums.dart`) — `{ granted, denied, permanentlyDenied, unknown }`. New statuses default to `unknown`. `permanentlyDenied` arises two ways: from the OS for **notifications** (the one runtime permission that can be marked "don't ask again"), and from `PermissionsCubit` for a gate-able permission it has inferred is blocked by restricted settings (§3.5). `blockedByRestrictedSettings` is what separates the two, since the recovery differs.

`domain/repositories/permission_repository.dart` — the contract:

```dart
abstract interface class PermissionRepository {
  Future<List<PermissionStatus>> statuses();
  Future<PermissionStatus> status(AppPermission permission);
  Future<void> request(AppPermission permission);

  /// Permissions that read as granted on the last successful check — the
  /// gate's fallback when a live read comes back `unknown` (§3.2).
  Future<Set<AppPermission>> lastKnownGranted();

  /// Play Store install? Drives the restricted-settings inference (§3.5).
  Future<bool> installedOutsidePlay();

  /// Opens the app's own system settings page (the ⋮ → "Allow restricted
  /// settings" screen).
  Future<void> openAppSettings();
}
```

`installedOutsidePlay()` reads `PackageInfo.fromPlatform().installerStore` (`package_info_plus`, which calls `getInstallSourceInfo().initiatingPackageName` on API 30+ — immutable after install, unlike the *installing* package) and compares against `com.android.vending`. It returns `false` on any throw: an unknown installer means don't guess and don't nag. `openAppSettings()` delegates to `permission_handler`'s `openAppSettings()`. **Neither goes through the MethodChannel** — both are already provided by existing dependencies.

### 3.2 Data layer — how status/request map to the platform

`data/repositories/permission_repository_impl.dart` (`PermissionRepositoryImpl`, wraps `EngineChannel` + `LocalStore`).

Everything is gated on `PlatformCapabilities.usesAndroidPermissionFunnel` (Android-only, from `lib/core/platform/platform_capabilities.dart`):

- **Off Android:** `statuses()` returns `const []`. This is deliberate — an empty list makes `PermissionsCubit.allRequiredGranted` **vacuously true**, so the splash gate skips the permissions stage and routes straight to `/home` (the iOS "preview" build has no engine to permission). `status()` returns `denied`; `request()` is a no-op.

- **On Android**, `status(permission)` reads live state per kind — and the channel-backed reads are **tri-state** (`EngineChannel.invokeBoolOrNull`: `true`/`false` from the OS, `null` = "the call didn't answer"):

  | Permission | Status check (`EngineChannel`) |
  |------------|-------------------------------|
  | `accessibility` | `isAccessibilityEnabled` |
  | `overlay` | `canDrawOverlays` |
  | `usageAccess` | `hasUsageAccess` |
  | `batteryOptimization` | `isIgnoringBatteryOptimizations` |
  | `deviceAdmin` | `isDeviceAdminActive` |
  | `notificationListener` | `isNotificationListenerEnabled` |
  | `notifications` | `permission_handler` `Permission.notification.status` → `granted`, else `permanentlyDenied` when `isPermanentlyDenied` (don't-ask-again), else `denied`; **a plugin throw is caught and reads as `unknown`** — an uncaught rejection here used to fail the splash's `Future.wait` and hang the app on the splash |

  A `null` channel read is retried **once after 150 ms**; still `null` → the status is `PermissionState.unknown`, **never `denied`**. (Previously `null` was coerced to `false` → denied, so one flaky cold-start read re-opened the full permission setup wall for an already-set-up user.)

  `statuses()` iterates `AppPermission.values` in order and collects each `status(...)`, then **persists the granted set** (fire-and-forget) to Hive under `StoreKeys.grantedPermissions` — a JSON list of `AppPermission.name`s: every `granted` status is added, every definitive `denied`/`permanentlyDenied` is removed, and `unknown` leaves the stored entry untouched. `lastKnownGranted()` reads that set back (a corrupt blob reads as empty); it is the gate's memory in §3.3.

- `request(permission)` triggers the grant path per kind:

  | Permission | Request action |
  |------------|----------------|
  | `accessibility` | `openAccessibilitySettings()` — opens the system Accessibility screen |
  | `overlay` | `requestOverlay()` — "Display over other apps" screen |
  | `usageAccess` | `openUsageAccess()` — Usage-access settings |
  | `batteryOptimization` | `requestIgnoreBattery()` — battery-exemption prompt |
  | `deviceAdmin` | `requestDeviceAdmin()` — device-admin activation prompt |
  | `notificationListener` | `openNotificationListenerSettings()` — the system "Notification access" list (no programmatic grant exists) |
  | `notifications` | if `Permission.notification.isPermanentlyDenied` → `openAppSettings()`; else `Permission.notification.request()` — in-app runtime dialog |

  A plain `request()` no-ops once notifications is permanently denied (don't-ask-again), so the branch sends the user to the app's system settings screen instead, giving a real recovery path; on resume the funnel re-checks and the card flips to granted.

  Important consequence: **only `notifications` resolves with an inline dialog**. The other five hand off to a full-screen system settings activity that returns no synchronous grant result. That is why the funnel re-checks on resume and after a short delay (below) rather than trusting a return value from `request()`.

The channel methods themselves are thin wrappers over the `com.errorxperts.detoxo/commands` `MethodChannel` (`lib/core/platform_channels/engine_channel.dart`) and no-op off Android via `PlatformCapabilities`. The native intents/receivers behind them (accessibility service, `SYSTEM_ALERT_WINDOW`, usage-access, battery, `DetoxoDeviceAdminReceiver`) are documented in the native/manifest docs.

### 3.3 Presentation

**`PermissionsCubit`** (`presentation/permissions_cubit.dart`) — `Cubit<List<PermissionStatus>>`, initial state `[]`:

- `refresh()` → loads `_repo.statuses()` **and** `_repo.lastKnownGranted()`, then emits (with the restricted-settings rewrite of §3.5 applied).
- `request(permission)` → calls `_repo.request(...)`, waits **400 ms** (system dialogs/settings are async), then `refresh()`s to reflect the new state.
- **`statusFor(kind)`** — the live row for one permission, or a default `unknown` row when the list has no entry yet. The one lookup every truthful "Needs X — tap to allow" row and `requestPermission` use, instead of re-implementing the `firstWhere`.
- **`effectivelyGranted(status)`** — the gate's per-permission truth, public so the UI shares it: `granted`, **or** a live `unknown` reading that is in `lastKnownGranted`. A definitive `denied` is `false`, regardless of history. Shared with the screen so the cards, the "N of M" progress row and the Continue button can never contradict each other (EVO-014).
- `allRequiredGranted` — the getter the splash gate reads; it simply runs `effectivelyGranted` over every required permission — one flaky channel call at cold start must not send a set-up user back to the setup wall. On an empty state (iOS) `.every` on an empty list is `true`.
- `needsRestrictedFix` (§3.5) explicitly **never fires for an `unknown` reading** — a channel hiccup is not a refusal and must not be relabelled `permanentlyDenied`.

DI: registered as a global `BlocProvider` in `lib/main.dart` (`PermissionsCubit(sl<PermissionRepository>())`); `PermissionRepository` → `PermissionRepositoryImpl` is a lazy singleton in `lib/core/di/injector.dart`.

**`PermissionsScreen`** (`presentation/permissions_screen.dart`) — the guided funnel UI, title **"Set up protection"**:

- A `WidgetsBindingObserver` that calls `PermissionsCubit.refresh()` on `initState` **and** on every `AppLifecycleState.resumed`. This is the key UX move: the user leaves to a system settings screen, flips a toggle, and returns — the list updates live to reflect what they just granted. (Independently of this screen, `AppResumeSync` in `lib/app/app_resume_sync.dart` also runs `PermissionsCubit.refresh()` on **every** app resume, so the persisted granted set stays fresh even when the user never revisits the funnel.)
- Splits statuses into **"Required to block"** and **"Recommended"** sections (by `kind.required`), each an animated `EntranceList` of `PermissionCard`s.
- A progress row: a `ProgressBar` plus "*grantedReq* of *totalRequired*" — counted with `cubit.effectivelyGranted`, the **same predicate as the gate**, so the row, the cards and the Continue button can never contradict each other under a flaky (unknown) read.
- Each card shows an icon, the permission `label`, its `why`, a granted/needed indicator, and an action wired to `requestPermission(context, status.kind)`. `granted:` is the card's `effectivelyGranted` value; a **genuinely unknown** status (live `unknown` with no granted history) sets `PermissionCard(unknown: true)`, which renders a neutral **"Checking…"** row — no Grant button, no denied red (EVO-014; the next refresh settles it). Otherwise the action reads **Grant** normally, **Open settings** when `permanentlyDenied` (so a don't-ask-again notification permission points at system settings instead of a dead button), or **Fix this** when `blockedByRestrictedSettings` (`PermissionCard(actionLabel: ...)`). Covered by `test/permission_unknown_ui_test.dart`.
- Bottom `PrimaryButton`: while `allRequiredGranted` is false it reads **"Grant required permissions"** and is **disabled**; once both required permissions are granted it becomes **"Continue"** and `context.go(Routes.home)`.

Per-permission icons (`_iconFor`, presentation-only; the `why` copy is on the enum — see §3.1):

| Permission | Icon |
|------------|------|
| accessibility | `accessibility_new` |
| overlay | `layers` |
| notifications | `notifications` |
| usageAccess | `bar_chart` |
| batteryOptimization | `battery_charging_full` |
| deviceAdmin | `shield` |
| notificationListener | `notifications_off` |

**`requestPermission(context, kind)`** (`presentation/permission_actions.dart`) is the single grant entry point for all three surfaces (funnel, settings sheet, dashboard card), so the disclosure and recovery flows cannot drift between them. In order:

1. If the status is `blockedByRestrictedSettings` → open `RestrictedSettingsSheet` instead. Another trip to the system toggle would just repeat the dead end.
2. If `_disclosureFor(kind)` returns copy → show that **prominent disclosure** dialog first, *before* the grant. Two kinds have one, both because their scope is wider than their name suggests: `accessibility` (Play's Accessibility API policy requires an in-app disclosure of what the service does and why — the copy mirrors `accessibility_service_description` in `android/app/src/main/res/values/strings.xml`, keep the two in sync) and `notificationListener` (Android hands a listener *every* notification on the device; the copy says so plainly, and states that only the sending app's name is read and nothing is stored or transmitted — [29](29-notification-suppression.md) §5). Declining returns without requesting.
3. Otherwise → `cubit.request(kind)`.

### 3.4 Restricted settings / ECM recovery

Android 13+ **Restricted Settings** and Android 15+ **Enhanced Confirmation Mode (ECM)**
refuse the Accessibility, overlay and device-admin toggles for any app whose installer is
not trusted. A sideloaded APK is untrusted; **a Play Store install is exempt**. The user
sees *"Restricted setting"* or a shield with *"App was denied access"*, the toggle stays
off, and — before this flow existed — the app had no idea anything had gone wrong.

**There is no API to detect it.** Verified against the Android 35 SDK sources:

- `AppOpsManager.OPSTR_ACCESS_RESTRICTED_SETTINGS` is `@hide` — absent from the public `android.jar`.
- The op is declared `setRestrictRead(true)`, so a normal app's `unsafeCheckOpNoThrow` gets a `SecurityException`.
- Under ECM its default is `MODE_DEFAULT`, **not** `MODE_ALLOWED` — a `hasUsageAccess`-style `== MODE_ALLOWED` check would report "restricted" for every app, Play installs included.
- `android.app.ecm.EnhancedConfirmationManager` is not in the public SDK.

So detection is **behavioural**, and lives in `PermissionsCubit`:

| Signal | Source |
|---|---|
| Not installed by Play | `repo.installedOutsidePlay()`, cached for the session |
| The permission is gate-able | `AppPermission.restrictedWhenSideloaded` — accessibility, overlay, device admin |
| Still denied after **2** grant attempts | `_attempts` map, incremented in `request()` |

All three must hold. `refresh()` then rewrites that status to
`PermissionState.permanentlyDenied`, which `blockedByRestrictedSettings` distinguishes from
the notification don't-ask-again case.

Why **two** attempts, not one: a single failure is ordinary noise — the user backs out,
gets distracted, or taps Grant just to look. Two round-trips with no change is a stuck
user. `Continue` stays disabled until both required permissions are granted, so they will
try again; there is no dead end. Attempts are cleared for any permission that comes back
granted (self-healing) and wholesale when the user opens App info.

`_ecmGated` deliberately excludes `usageAccess` and `batteryOptimization` — not behind the
gate, so two failures there mean something else — and `notifications`, which has its own
legitimate `permanentlyDenied` path.

**The UX** is passive: no auto-opening sheet on resume (intrusive, and it would fire
mid-rebuild). Instead the card's own button becomes **Fix this**, so a stuck user cannot
miss it — it is the only control there. It opens `RestrictedSettingsSheet`
(`presentation/widgets/restricted_settings_sheet.dart`): four numbered steps and an
**Open app info** button that pops the sheet and calls
`PermissionsCubit.openAppSettings()`.

Copy is **version-agnostic** — the escape hatch is the same ⋮ → *Allow restricted
settings* on 13/14 and 15+, and only the system dialog's wording differs, so one sentence
naming both variants covers it. No `sdkInt` branch, and therefore no `deviceInfo()` read.

The allowance is **per app, not per permission**: one confirmation unblocks all three
toggles.

Covered by `test/permissions_restricted_settings_test.dart` (threshold, gate-able set,
Play-install negative case, and the clear-on-open-settings path).

### 3.5 Re-entry after onboarding

The same `PermissionsCubit` is reused in **Settings** (`lib/features/settings/presentation/settings_screen.dart`): a `_PermissionsTile` summarising status ("All set" / "*granted*/*total*") that opens a `_PermissionSheet` listing every permission with **Grant**/**Enable** actions. Settings also `refresh()`es the cubit on init and on resume, so a user who skipped optional permissions during the funnel can grant them later without re-running onboarding.

---

## 4. Manufacturer-specific accessibility guidance

**None is present in the code**, with one system-level exception: the restricted-settings / ECM recovery in §3.4, which is an Android-version behaviour rather than an OEM one. The onboarding, permissions, bootstrap and splash sources contain no OEM-specific branches or copy (no Xiaomi/MIUI, Oppo, Vivo, Huawei, Samsung, OnePlus, Realme, autostart, etc.). The accessibility request simply opens the standard system Accessibility settings via `openAccessibilitySettings()`; battery-optimization exemption is offered as its own recommended permission. Any OEM autostart/background-restriction guidance would be a **follow-up** (docs/UX), not something the app currently detects or special-cases.

---

## 5. End-to-end sequence (first run, Android)

1. Cold launch → `/` splash → `runBootstrap()` loads settings/permissions/pin, seeds the enabled-platform set from installed defaults, then opens `AppGate` and fires the background legs (counter widget, `syncEngineBlocklists()`, rules/limit/streak reloads).
2. `onboarded == false` → the redirect sends the user to `/onboarding`. They walk **welcome → survey → projection → selection → commitment**, each answer written to `StoreKeys.onboardingProgress` as it is given. Killing the app at any point resumes on that step.
3. Leaving `commitment` advances the record to `permissions`, seeds the daily limit (dialled value or the 90-minute default) and flips `onboarded: true` through `SettingsCubit` — the redirect routes on to `/permissions`.
4. `/permissions` funnel. User grants **Accessibility** and **Display over apps** (required) via system screens; returning each time re-checks on resume. Optional permissions (notifications, usage, battery, device-admin) offered but not blocking. The redirect leaves them on the screen once the required two are in.
5. The moment `allRequiredGranted` flips true, `StarterRuleSync` writes **exactly one** rule from the survey, marks the record `completed` and clears it — so the first thing that happens after granting is that Detoxo does something.
6. **Continue** → `/home`.
7. Next launch: the bootstrap finds `onboarded == true`, no app-scope PIN (unless one was set), required permissions granted → the redirect lands straight on `/home`. If an app-scope PIN was later configured, gate step 3 diverts to `/pin/lock` first. An **upgrading** install has no progress record at all, which is exactly why completion lives on `AppSettings.onboarded`: it is never re-onboarded.

---

## Source files

- `lib/app/splash_screen.dart`
- `lib/features/onboarding/presentation/widgets/screen_time_dial.dart` (`ScreenTimeDial` — the draggable daily-limit gauge)
- `lib/features/onboarding/onboarding.dart` (barrel: screen + progress record + starter rule)
- `lib/features/onboarding/domain/entities/onboarding_progress.dart` (`OnboardingStepId`, `ScreenTimeBand`, `MattersMost`, `OnboardingProgress`)
- `lib/features/onboarding/domain/onboarding_script.dart` (`surveyQuestions` — the survey as data)
- `lib/features/onboarding/domain/starter_rule.dart` (`starterRule` — survey → one M3 rule)
- `lib/features/onboarding/domain/repositories/onboarding_repository.dart`
- `lib/features/onboarding/data/repositories/onboarding_repository_impl.dart`
- `lib/features/onboarding/presentation/onboarding_cubit.dart` (the persisted step machine)
- `lib/features/onboarding/presentation/onboarding_screen.dart` (the walker + chrome)
- `lib/features/onboarding/presentation/steps/{survey,projection,selection}_step.dart`
- `lib/features/onboarding/presentation/widgets/caught_hero.dart` (`CaughtHero` — the welcome hero)
- `lib/features/onboarding/presentation/widgets/commitment_hero.dart` (`CommitmentHero` — the commitment hero)
- `lib/features/onboarding/presentation/widgets/screen_time_dial.dart` (`ScreenTimeDial` — the daily-limit dial)
- `lib/features/limits/rules/domain/entities/rule_preset.dart` (`RulePreset.sleep` / `.workHours` / `.doomscrollBudget`)
- `lib/app/bootstrap.dart` (`runBootstrap` — ordered, individually-guarded app-start work)
- `lib/app/starter_rule_sync.dart` (`StarterRuleSync` — writes the starter rule on the grant edge)
- `lib/core/navigation/app_gate.dart` (`AppGate` — the whole gate order)
- `lib/core/storage/local_store.dart` (`StoreKeys.onboardingProgress`)
- `test/onboarding_resume_test.dart` (resume at every step, per-answer writes, persist-before-emit, migration)
- `test/starter_rule_test.dart` (the survey → rule mapping, selection carry-over, wire contract)
- `test/app_gate_test.dart` (the gate order, pass-through rules, session flags)
- `test/routes_registered_test.dart` (every declared path resolves)
- `lib/features/limits/daily_limit/presentation/daily_limit_cubit.dart` (`DailyLimitCubit.setLimit` — seeds the limit on finish, via the app-wide provider)
- `lib/features/permissions/permissions.dart`
- `lib/features/permissions/presentation/permission_actions.dart` (`requestPermission` — the single grant entry point; prominent disclosure + restricted-settings routing)
- `lib/features/permissions/presentation/widgets/restricted_settings_sheet.dart` (`RestrictedSettingsSheet`)
- `lib/app/app_resume_sync.dart` (app-wide permission re-check on every resume)
- `lib/app/engine_sync.dart` (`syncEngineBlocklists` — splash + resume blocklist drift repair)
- `lib/core/design_system/components/permission_card.dart` (`PermissionCard` incl. the neutral `unknown` "Checking…" row)
- `lib/core/storage/local_store.dart` (`StoreKeys.grantedPermissions` — the persisted granted set)
- `test/permissions_restricted_settings_test.dart`
- `test/permissions_persistence_test.dart` (tri-state reads, retry, persisted-set gate fallback)
- `test/permission_unknown_ui_test.dart` (unknown renders "Checking…", not denied; row/card/button agreement)
- `lib/features/permissions/domain/entities/permission_status.dart`
- `lib/features/permissions/domain/repositories/permission_repository.dart`
- `lib/features/permissions/data/repositories/permission_repository_impl.dart`
- `lib/features/permissions/presentation/permissions_cubit.dart`
- `lib/features/permissions/presentation/permissions_screen.dart`
- `lib/core/navigation/app_router.dart`
- `lib/core/navigation/routes.dart`
- `lib/core/platform/platform_capabilities.dart`
- `lib/core/platform_channels/engine_channel.dart`
- `lib/features/blocking/shared/domain/entities/enums.dart` (`PermissionState`, `PinScope`)
- `lib/features/blocking/shared/domain/entities/app_settings.dart` (`onboarded`)
- `lib/features/access_protection/domain/entities/pin_config.dart` (`isConfigured`, `guards`)
- `lib/features/settings/presentation/settings_screen.dart` (permission re-entry tile/sheet)
- `lib/core/di/injector.dart`, `lib/main.dart` (DI/provider wiring)
