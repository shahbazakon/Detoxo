# Onboarding & Permission Funnel

How a first-run Detoxo user gets from cold launch to a working blocker: the value-prop onboarding intro, the guided runtime-permission funnel, and the exact splash-screen gate that decides which of those (if any) to show.

The whole flow is driven **imperatively from the splash screen** after app state loads — there is no `go_router` `redirect`. The router's `initialLocation` is always `/` (splash); the splash then `context.go(...)`s to the right destination.

---

## 1. The splash gate (source of truth)

`lib/app/splash_screen.dart` boots the app and routes. On the first post-frame callback it runs `_bootstrap()`:

1. **Load state in parallel** (`Future.wait`) — only what the routing decision reads:
   - `SettingsCubit.bootstrap()` — app settings (incl. the `onboarded` flag)
   - `PermissionsCubit.refresh()` — current permission statuses
   - `PinCubit.load()` — PIN configuration

   `TargetsCubit.load()` is the slow leg (native config push + installed-package scan) and stays **off the critical path**: it is awaited only on a first run (for the seeding below) and fired `unawaited` otherwise.
2. **First-run seeding of the enabled set.** If `settings.state.enabledPlatformIds` is empty, it awaits `targets.load()` and seeds from every target that is both `defaultEnabled` and `isInstalled` (via `settings.setEnabledPlatforms(...)`). Apps the user doesn't have are never pre-enabled.
3. **Content-counter widget refresh** (fire-and-forget, never blocks routing): `_refreshReelCounterWidget()` reads `ContentCounterRepository.current()` and pushes it to the home-screen widget via `HomeWidgetRepository.pushSnapshot(...)`. The reel counter runs natively and is on by default, independent of blocking.
4. **Blocklist drift repair** (fire-and-forget): `syncEngineBlocklists()` (`lib/app/engine_sync.dart`) pushes the protected apps, the merged web blocklist and the whole-app blocks to the native engine so it matches Dart without any screen ever being opened. The same shared helper is the resume path's heavy leg ([12](12-analytics-notifications-resilience.md) §3.2) — the splash no longer carries its own copy of the trio.

Then the gate, **in this exact order**:

| # | Condition | Route | Notes |
|---|-----------|-------|-------|
| 1 | `!settings.state.onboarded` | `Routes.onboarding` (`/onboarding`) | Haven't seen the intro yet |
| 2 | `pin.state.isConfigured && pin.state.guards(PinScope.app)` | `Routes.pinLock` (`/pin/lock`) | An **app-scope** PIN is set |
| 3 | `!permissions.allRequiredGranted` | `Routes.permissions` (`/permissions`) | Missing a required permission |
| 4 | (else) | `Routes.home` (`/home`) | Fully set up |

So the canonical funnel is **onboarding → PIN lock → permissions → home**. Each stage is checked only if the earlier ones passed; the first failing condition wins and returns.

Notes on the gate:

- **`onboarded`** is a boolean on `AppSettings` (`lib/features/blocking/shared/domain/entities/app_settings.dart`), persisted through the settings store.
- **PIN gate** uses `PinConfig.isConfigured` (`type != PinType.none`) **and** `guards(PinScope.app)` — i.e. only a PIN whose `scopes` set contains `PinScope.app` (wire `DETOXO_APP`) blocks the launch. A PIN scoped only to settings/plan-switch/etc. does **not** gate the splash. On a genuine first run no PIN exists, so this stage is skipped. (PIN mechanics — types, salted hashing, lockout ladder, biometrics, recovery — live in the access-protection docs; the splash only reads `PinCubit` state.)
- **Required-permission gate** uses `PermissionsCubit.allRequiredGranted` (see §3).
- The `unawaited(...)` widget refresh means a slow/absent native side can never stall the gate.

The `build()` method renders a branded splash (Detoxo logo, "Reclaim your attention", spinner) while `_bootstrap()` runs.

---

## 2. Onboarding intro (`onboarding` feature)

`lib/features/onboarding/` is a **presentation-only feature** — its public barrel (`onboarding.dart`) exports just `OnboardingScreen`; there is no data/ or domain/ layer.

`presentation/onboarding_screen.dart` is a 5-page horizontal `PageView` over the ambient gradient (`GlassScaffold`). Each page is a **problem→solution** beat driven by a `_HeroKind` enum, and every hero is a **coded illustration built from the design system** (no bespoke Lottie/image assets):

| Page | `_HeroKind` | Accent | Title | Hero / interaction |
|------|-------------|--------|-------|--------------------|
| 0 | `welcome` | `AppColors.seed` | "Take your time back" | brand logo (`assets/images/detox_logo_no_bg.png`) in an accent halo, breathing (`_WelcomeHero`) |
| 1 | `caught` | `AppColors.seed` | "Caught the moment it starts" | `CaughtHero` — real app-pack icons ring a rising "reel" card a shield sweeps away; `Pill` footer "Blocks the reels, not the app" |
| 2 | `plans` | `AppColors.onbTeal` | "Not all-or-nothing" | `PlanPreview` — tap any of the five plan chips to morph the badge + promise line |
| 3 | `limit` | `AppColors.onbTeal` | "See the number, set the line" | `_ReelCountUp` (counts up once) above the interactive `ScreenTimeDial` |
| 4 | `stick` | `AppColors.onbViolet` | "Make it stick" | `CommitmentHero` — shield with a lock that clicks shut + an always-on `StatusDot`; three benefit rows |

Copy is **value/outcome-first**: each page opens with the user's pain and answers it with what Detoxo does — the bottomless feed caught in the moment (page 1), the five flexible plans that fit how you change (page 2), an honest on-device reel count + a daily limit you set (page 3), and PIN/uninstall/always-on protection that makes it stick (page 4). Deep per-plan teaching is deliberately **deferred to the in-context dashboard feature showcase** (`additional_feature/showcase_view`); onboarding only sells the value and hands off. Nothing is requested or persisted per-page except the limit dial on page 3.

**The daily-limit step (page 3, `_LimitStep`).** Page 3 — "See the number, set the line" — first surfaces the on-device reel counter as a tangible number via `_ReelCountUp` (an illustrative "reels a day, typically" ticker that counts up **once** on entry, respecting reduce-motion), then presents the interactive **`ScreenTimeDial`** (`presentation/widgets/screen_time_dial.dart`) — a draggable 270° radial gauge (range **15 min – 5 h**, **15-minute** steps, default **90 min**) that visually mirrors the dashboard screen-time ring. Dragging (or tapping) the arc updates the value, which animates in the centre and fires a **selection haptic** on each new step; it's a Semantics slider (increase/decrease step) for accessibility. The selection is held in local `_draftLimit` state (nothing is saved until finish) and seeds the dashboard's screen-time ring max. Because the dial owns its drag gestures, the `PageView` horizontal swipe is **suspended on this page** (`NeverScrollableScrollPhysics`) — Back/Next still navigate. If the user skips the step, `_finish()` falls back to the **90-minute** default.

UI mechanics:
- **Coded heroes, no external art:** the welcome/caught/stick heroes (`_WelcomeHero`, `CaughtHero`, `CommitmentHero`) and the plans/limit interactions are composed entirely from design-system primitives (`GlassContainer`/`IconBadge`/`AppChip`/`StatusDot`/`ScreenTimeDial`) and `flutter_animate` — there are no Lottie/illustration assets to load or fall back for. All motion is guarded by `MediaQuery.maybeDisableAnimationsOf` and degrades to a static end-state under reduce-motion.
- **Parallax:** the welcome/caught/stick heroes drift at 60px × page-delta relative to the swipe (`Transform.translate` driven by the `PageController`) in `_PageView`.
- **Haptics:** a **selection** tick on every page change (`onPageChanged`) and on each dial step, and a **success** pulse when `_finish()` runs (`AppHaptics`, gated by the global vibration setting).
- **Skip** (top-right `GhostButton`) — visible on pages 0–3, fades out (opacity 0, disabled) on the last page (index 4).
- **Back** (top-left `GhostButton`) — hidden (opacity 0, disabled) on page 0, visible from page 1 onward; steps back one page via `PageController.previousPage`. Gives a discoverable way back for screen-reader users, since TalkBack intercepts the `PageView` swipe.
- **Bottom bar** — a segmented filling progress bar (`_ProgressBar`: five segments, each filling with the current page accent as the user advances; wrapped in `Semantics(label: 'Step N of M')` so progress is announced) plus a full-width `PrimaryButton` labelled **"Next"** on pages 0–3 and **"Get started"** on the last page, tinted with the current page's accent.

**Finishing** (`_finish()`, reached by *Skip*, or by *Get started* on the last page via `_next()`):

```dart
final settings = sl<SettingsRepository>();
// Seed the dashboard ring's daily limit from the quick-pick (or 90 min default)
// through the app-wide cubit, so the dashboard reflects it live.
final dailyLimit = context.read<DailyLimitCubit>();
AppHaptics.success(); // completion pulse
await settings.save((await settings.load()).copyWith(onboarded: true));
await dailyLimit.setLimit(_draftLimit ?? _defaultLimit);
if (mounted) context.go(Routes.splash);   // NOT /permissions — see note 2
```

Three things to note:

1. It persists `onboarded: true` **directly through `SettingsRepository`** (resolved from `sl`),
   not through `SettingsCubit` — because `tool/check_boundaries.sh` forbids a feature importing
   another feature's `presentation/`, and the cubit lives in `blocking/shared/presentation/`.
   The domain contract is the only legal handle onboarding has on settings.
2. **It navigates back to the splash (`/`), not straight to `/permissions`.** This is load-bearing,
   not cosmetic. A raw repository write persists the flag but leaves `SettingsCubit.state` stale at
   `onboarded: false`, and `_commit` is `emit → save → pushSettings` with no repo→cubit feedback —
   so the next `_commit` from *any* setter (the dashboard showcase Skip, picking a mode, flipping a
   switch) does `state.copyWith(...)` carrying that stale `false` and writes it **straight back over
   Hive**, walking the user through onboarding again on the next cold launch. Re-entering the splash
   re-runs `SettingsCubit.bootstrap()`, which reloads the flag that was just persisted, so nothing
   can clobber it; the splash gate then routes on to `/permissions` itself — and, unlike the old
   direct jump, honours the PIN gate on the way. This was a real defect, caught on a physical device
   by `integration_test/app_e2e_test.dart` (see `.claude/skills/detoxo-auto-test/SKILL.md`). The
   general rule: **an `AppSettings` field written behind the cubit's back must be followed by a
   cubit reload**, or it will be silently reverted.
3. It **seeds the daily limit** through the **app-wide `DailyLimitCubit`** (`context.read<DailyLimitCubit>().setLimit(...)`, the quick-pick choice or the 90-minute default) — not a direct `DailyLimitRepository.save`, so the value re-emits to the dashboard's screen-time ring **live**. This is the value the ring reads as its max (the ring's fill comes from native usage time, not `DailyLimit.consumed`). See [07-daily-limit-scheduler.md](07-daily-limit-scheduler.md).

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

  `why` lives on the enum because three surfaces render it (funnel, settings sheet, dashboard card) and the previously duplicated copies had already drifted. Icons stay in presentation — an `IconData` field would drag `flutter/material` into a domain layer that otherwise imports only `equatable`.

  **Gate-able** marks `restrictedWhenSideloaded`: the toggles Android's restricted-settings / ECM gate can silently refuse (§3.5).

  Only **accessibility** and **overlay** are required — they are the minimum for the blocker to detect and to draw the block/PIN screen. Everything else is "recommended".

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
  | `notifications` | if `Permission.notification.isPermanentlyDenied` → `openAppSettings()`; else `Permission.notification.request()` — in-app runtime dialog |

  A plain `request()` no-ops once notifications is permanently denied (don't-ask-again), so the branch sends the user to the app's system settings screen instead, giving a real recovery path; on resume the funnel re-checks and the card flips to granted.

  Important consequence: **only `notifications` resolves with an inline dialog**. The other five hand off to a full-screen system settings activity that returns no synchronous grant result. That is why the funnel re-checks on resume and after a short delay (below) rather than trusting a return value from `request()`.

The channel methods themselves are thin wrappers over the `com.errorxperts.detoxo/commands` `MethodChannel` (`lib/core/platform_channels/engine_channel.dart`) and no-op off Android via `PlatformCapabilities`. The native intents/receivers behind them (accessibility service, `SYSTEM_ALERT_WINDOW`, usage-access, battery, `DetoxoDeviceAdminReceiver`) are documented in the native/manifest docs.

### 3.3 Presentation

**`PermissionsCubit`** (`presentation/permissions_cubit.dart`) — `Cubit<List<PermissionStatus>>`, initial state `[]`:

- `refresh()` → loads `_repo.statuses()` **and** `_repo.lastKnownGranted()`, then emits (with the restricted-settings rewrite of §3.5 applied).
- `request(permission)` → calls `_repo.request(...)`, waits **400 ms** (system dialogs/settings are async), then `refresh()`s to reflect the new state.
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

**`requestPermission(context, kind)`** (`presentation/permission_actions.dart`) is the single grant entry point for all three surfaces (funnel, settings sheet, dashboard card), so the disclosure and recovery flows cannot drift between them. In order:

1. If the status is `blockedByRestrictedSettings` → open `RestrictedSettingsSheet` instead. Another trip to the system toggle would just repeat the dead end.
2. If the kind is `accessibility` → show the **prominent disclosure** dialog first (Play's Accessibility API policy requires an in-app disclosure of what the service does and why, *before* the grant). The copy mirrors `accessibility_service_description` in `android/app/src/main/res/values/strings.xml`; keep the two in sync. Declining returns without requesting.
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

**None is present in the code**, with one system-level exception: the restricted-settings / ECM recovery in §3.4, which is an Android-version behaviour rather than an OEM one. The onboarding, permissions, and splash sources contain no OEM-specific branches or copy (no Xiaomi/MIUI, Oppo, Vivo, Huawei, Samsung, OnePlus, Realme, autostart, etc.). The accessibility request simply opens the standard system Accessibility settings via `openAccessibilitySettings()`; battery-optimization exemption is offered as its own recommended permission. Any OEM autostart/background-restriction guidance would be a **follow-up** (docs/UX), not something the app currently detects or special-cases.

---

## 5. End-to-end sequence (first run, Android)

1. Cold launch → `/` splash → `_bootstrap()` loads settings/permissions/pin (targets off the critical path), seeds the enabled set from installed defaults, refreshes the counter widget, and fires the blocklist drift repair (`syncEngineBlocklists()`).
2. `onboarded == false` → `/onboarding`. User swipes/skips the 5-page value-first intro (five problem→solution beats, incl. the reel count-up + daily-limit dial on page 3); finishing persists `onboarded: true`, seeds the daily limit (dialled value or 90 min default), and returns to the **splash** (`/`), which re-bootstraps `SettingsCubit` from the freshly written flag and re-runs the gate — landing on `/permissions`.
3. `/permissions` funnel. User grants **Accessibility** and **Display over apps** (required) via system screens; returning each time re-checks on resume. Optional permissions (notifications, usage, battery, device-admin) offered but not blocking.
4. Once both required are granted, **Continue** → `/home`.
5. Next launch: splash finds `onboarded == true`, no app-scope PIN (unless the user set one), required permissions granted → routes straight to `/home`. If an app-scope PIN was later configured, step 2 of the gate diverts to `/pin/lock` first.

---

## Source files

- `lib/app/splash_screen.dart`
- `lib/features/onboarding/onboarding.dart`
- `lib/features/onboarding/presentation/onboarding_screen.dart` (5-page problem→solution intro + `_LimitStep` + `_ReelCountUp` + `_ProgressBar`; seeds `DailyLimit`)
- `lib/features/onboarding/presentation/widgets/screen_time_dial.dart` (`ScreenTimeDial` — the draggable daily-limit gauge)
- `lib/features/onboarding/presentation/widgets/caught_hero.dart` (`CaughtHero` — page 1 app-icon ring + reel-catch)
- `lib/features/onboarding/presentation/widgets/plan_preview.dart` (`PlanPreview` — page 2 interactive plan chooser)
- `lib/features/onboarding/presentation/widgets/commitment_hero.dart` (`CommitmentHero` — page 4 shield/lock hero)
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
