# Overview & Architecture

Detoxo is a shipped Android app that detects short-form content — Reels, Shorts,
infinite feeds, stories/statuses — inside *other* apps and pulls the user back
out (Back / close / lock), plus a decoupled counter that tallies how many short
videos you scroll. It is built in **Flutter + flutter_bloc (Cubit)** with a
native **Android AccessibilityService** engine doing the hot detection/block
work. Package / application id: `com.errorxperts.detoxo`; asset & vendor
namespace `errorxperts`.

This is the top-level orientation doc. Sibling engineering docs drill into each
subsystem — see the detection engine, plans, content counter, permissions,
persistence, and channel-contract docs alongside this file. End users are served
by the `../info_docs/` set.

> iOS is **unsupported**: there is no AccessibilityService equivalent, so the
> app shows an "unsupported" screen and gates the entire native engine off. See
> [The native ↔ Dart boundary](#the-native--dart-boundary) and
> `lib/app/unsupported_screen.dart`.

---

## What Detoxo does (feature inventory)

| Area | What it does | Live in this build? |
|---|---|---|
| Reel/Short detection + block | Native AccessibilityService detects short-video surfaces via a 3-stage view-id scan and blocks (Back / kill / lock) | ✅ Native, real device |
| Blocking plans | `blockAll`, `curious` (user label **Conscious**), `oneReel`, `paused` | ✅ Honored by the engine |
| Conscious plan | Earn-as-you-abstain time-bank; a 1 Hz accountant lets reels play while the bank has allowance, then presses Back when drained | ✅ |
| Pause | Clock-based window (`pauseUntil`) that suspends blocking | ✅ |
| Content counter | Side-effect-free counting pass (decoupled from blocking) → overlay bubble + home-screen widget | ✅ Native, on by default |
| Blocklist | Data-driven from bundled `platforms_config.json`; install-aware | ✅ |
| App blocker / Web blocker / Daily limit | Custom whole-app blocks (HOME bounce) and web host matching run natively; daily limit is UI + persistence | ✅ App + web enforced natively; native usage/daily-limit enforcement is the remaining follow-up |
| Access protection (PIN) | PIN setup/lock/recovery, biometric, retry lockout | ✅ (`local_auth` + secure storage) |
| Permissions funnel | Accessibility, overlay, usage access, battery exemption, device admin | ✅ (Android-only) |
| Premium / entitlement | Modeled; unlocked via a **local dev-unlock** (Settings → Developer) | ⚠️ No live Play Billing (swap-in) |
| Ads | Wired with Google **test** ad-unit ids; no live init in Dart | ⚠️ Test only |
| Analytics (block-event history) | Local block-event history (rolling 500-event buffer) | ⚠️ Local buffer only (no cloud sink) |
| Firebase telemetry | Analytics + Crashlytics + Performance, anonymised | ✅ Wired ([19](19-firebase-telemetry.md)); collection on in all builds |
| Onboarding / feedback | Showcase tips (`showcaseview`); in-app feedback emails to support | ✅ |

Support contact: `errorxperts@gmail.com`.

Anything marked ⚠️ is *modeled but not wired to a real backend*; those are called
out as planned / swap-in / follow-up throughout these docs.

---

## Architecture: feature-first Clean Architecture

Detoxo is organized **feature-first**. Each feature under `lib/features/<x>/`
owns the full vertical slice and is split into the three Clean-Architecture
layers:

```
lib/features/<feature>/
  data/           models + repository implementations (talk to channels/storage)
  domain/         entities + enums + repository *contracts* (pure Dart)
  presentation/   Cubits + screens + widgets
```

**Dependency rule** (inside a feature): `presentation → domain ← data`. Domain
is pure and depends on nothing app-specific; data and presentation both depend on
domain, never on each other.

**Cross-feature rule:** a feature may import another feature's **public barrel**
(`features/<x>/<x>.dart`) or its **`domain/`** contracts and entities — never
another feature's `data/` or `presentation/` internals. This keeps features
swappable and testable in isolation.

Public barrels currently exported:

```
access_protection · analytics · blocking · dashboard · limits
onboarding · permissions · settings
additional_feature/app_feedback · additional_feature/showcase_view
```

The **blocking** context is the core bounded context and is itself sub-structured:

```
lib/features/blocking/
  shared/     domain (AppSettings, BlockTarget, enums, repo contracts)
              + data (models, repo impls) + shared SettingsCubit  ← the spine
  engine/     presentation only (ServiceCubit — live service status)
  blocklist/  presentation only (TargetsCubit + blocklist UI)
  plans/      domain (session-phase rules) + data (bundled content)
              + presentation (pause, countdown, ConsciousCubit)
```

The **content_counter** context is likewise split into cooperating sub-features
(each with its own layers): `content_counter_core` (counting + snapshots),
`content_counter_bubble` (the floating overlay), `home_content_counter` (the
home-screen widget), and `content_counter_appearance` (bubble/widget styling
screens).

### Composition roots

A handful of directories exist specifically to *wire features together* and are
therefore exempt from the cross-feature rule:

- `lib/app/**` — the app entry (`main.dart`), `splash_screen.dart`, `unsupported_screen.dart`
- `lib/core/di/**` — the `get_it` service locator
- `lib/core/navigation/**` — the `go_router` graph
- `lib/features/dashboard/**` — the home shell that hosts feature tabs
- `lib/features/settings/**` — the settings orchestrator

### The boundary rule is enforced (with a caveat)

`tool/check_boundaries.sh` walks `lib/features/**/*.dart` (excluding generated
`*.g.dart` / `*.freezed.dart`), skips the composition roots above, and flags any
file that imports another feature's `data/` or `presentation/`.

> **Fixed (Aug 2026).** The script's patterns still carried the pre-rebrand package
> prefix while the real package is `detoxo`, so the grep never matched and the check
> reported "✓ No feature-boundary violations" unconditionally from the rename onward.
> It now greps `package:detoxo/` and genuinely enforces the rule.
>
> Repairing it surfaced **12 pre-existing violations** in one go. They are listed
> in `tool/boundaries_baseline.txt` and reported as warnings so the gate can be
> enforced today; anything *not* on that list fails the build. Most share a single
> root cause: `settings_cubit` is a cross-cutting cubit six features need, but it
> is only reachable through `blocking/shared/presentation/` — exporting it from the
> blocking barrel (or moving it to `core/`) clears five entries at once. Burn the
> list down and delete it; do not add to it.

---

## Runtime wiring: Cubit + get_it + go_router

Detoxo uses **Cubits only** (flutter_bloc) — no event-driven Blocs, no Riverpod.
State flows: repository (data) → Cubit (presentation) → widget.

### 1. Boot — `lib/main.dart`

`main()`:
1. `WidgetsFlutterBinding.ensureInitialized()` and sets a transparent system UI.
2. `await configureDependencies()` — builds the service locator.
3. Registers the global feedback action button, then `runApp(DetoxoApp())`.

`DetoxoApp` installs the app-wide Cubits with a `MultiBlocProvider`, each
resolving its repository from the locator `sl`:

| Cubit | Resolves |
|---|---|
| `ServiceCubit` | `EngineRepository` |
| `ConsciousCubit` | `EngineRepository` |
| `SettingsCubit` | `SettingsRepository`, `EngineRepository` |
| `TargetsCubit` | `ConfigRepository`, `EngineRepository` |
| `PermissionsCubit` | `PermissionRepository` |
| `PinCubit` | `PinRepository` |

`SettingsCubit` doubles as the app's appearance source: a `BlocSelector` drives
theme mode + ambient background, and a `BlocListener` mirrors the vibration
preference into `AppHaptics`. The tree then renders `AppResumeSync` →
`PinAutoRelock` → `MaterialApp.router` wired to the go_router config.
`AppResumeSync` (`lib/app/app_resume_sync.dart`) re-runs the Dart↔native syncs
on every app resume — cheap refreshes (permissions, service status, counter,
settings re-push) every time, the heavy config/blocklist re-push at most every
15 min (see [12-analytics-notifications-resilience.md](12-analytics-notifications-resilience.md) §3.2).

### 2. Dependency injection — `lib/core/di/injector.dart`

`get_it` instance is the global `sl`. `configureDependencies()`:

- Eagerly constructs `LocalStore` (async `create()`) and registers it as a
  singleton, plus a lazy `EngineChannel`.
- Registers every repository **interface → implementation** lazily
  (`ConfigRepository`, `SettingsRepository`, `EngineRepository`,
  `PermissionRepository`, `PinRepository`, the `limits` repos, `AnalyticsRepository`,
  `ContentRepository`, the content-counter repos, `FeedbackRepository`, …).

Registering by interface keeps Cubits testable — a fake repo swaps in without
touching presentation.

### 3. Navigation — `lib/core/navigation/`

`buildRouter()` (`app_router.dart`) returns a flat `GoRouter` whose paths live in
`routes.dart` (`Routes.splash`, `.onboarding`, `.permissions`, `.home`,
`.pinSetup`, `.pinLock`, `.settings`, `.webBlock`, `.appBlock`, `.dailyLimit`,
`.rules`, `.analytics`, `.bubbleStyle`, `.homeWidget`, `.unsupported`, …).
`initialLocation` is the splash route.

**Every constant in `routes.dart` is a path, and every one resolves.**
`test/routes_registered_test.dart` reads that file as text, regexes out each
`static const String`, and asserts it against the built `GoRouter`
configuration — no mirrors, no hand-kept list to drift. It exists because
`Routes.pause`, `Routes.curious` and `Routes.unsupported` sat declared but
unregistered for months: navigating to any of them failed at runtime and nothing
caught it. `pause` and `curious` were deleted (Pause and Conscious are dashboard
*modes*, not destinations); `unsupported` was registered against the
`UnsupportedScreen` that had been sitting orphaned in `lib/app/`.

**Gating is declarative: one `redirect`, reading one object.** It used to be an
imperative `context.go(...)` chain inside the splash, restated in the PIN
screen's `onUnlocked` and again (by bouncing back through the splash) at the end
of onboarding — three copies of one order.

`AppGate` (`lib/core/navigation/app_gate.dart`) is a small `ChangeNotifier`
holding `ready / supported / onboarded / pinLocked / permissionsOk`. The router
takes it as `refreshListenable` and its `redirect` is a one-liner delegating to
`AppGate.redirect(location)`. Cubits are `Stream`s and `refreshListenable` wants
a `Listenable`, so the flags are pushed in by `BlocListener`s in `main.dart`;
that also keeps `core/navigation/` free of feature imports and makes the whole
order unit-testable with no widget tree (`test/app_gate_test.dart`).

Two details that are load-bearing rather than cosmetic:

- `redirect` returns **null** when the location already *is* the destination.
  That is what stops `GoRouter` looping.
- `Routes.permissions` is **not** a pass-through screen. Once the two required
  permissions are granted the user is left on it — granting accessibility and
  overlay must not yank them away while they work through the recommended ones.
  They leave via its own Continue button. `splash`, `onboarding`, `pinLock` and
  `unsupported` *are* pass-throughs and eject to `home` once satisfied.
- The permissions gate only *applies* from a pass-through or `/home`
  (`_permissionsGateApplies`). The `PermissionsCubit` listener that feeds the
  gate fires on every app resume, so an unscoped gate destroyed in-progress work:
  lose accessibility while composing a rule at `/rules/edit` and the editor, its
  unsaved rule and its `state.extra` went with it. The user is funnelled on the
  next trip through home instead.
- `pinLocked` is a **session** flag, not a derived one: armed once by the
  bootstrap, cleared by a successful unlock. Re-locking on resume is
  `PinAutoRelock`'s job and does not route.

### 4. Bootstrap and gating order — `lib/app/bootstrap.dart`

The splash no longer routes; it renders the brand moment and calls
`runBootstrap(context)`, which ends by opening the gate. `_bootstrap()` used to
do four jobs in one method — cubit hydration, first-run seeding, native drift
repair *and* routing — of which only the last ~14 lines were routing.

`runBootstrap` is three phases, each step individually wrapped in the existing
`guardedSync` (`lib/app/engine_sync.dart`), so **one failing leg can never stop
app start**. Before this, a throw anywhere in the inline sequence left the user
on the spinner forever.

1. **Blocking** — only what the gate decision reads, in parallel:
   `settings.bootstrap()`, `permissions.refresh()`, `pin.load()`.
2. **First run only, strictly ordered** — seed the enabled-platform set from
   every target that is both `defaultEnabled` and `isInstalled`. Genuinely
   sequential: the seed needs `targets.load()` (native config push +
   installed-package scan, the slow leg) to have finished. Apps the user does
   not have are never pre-enabled.
3. **Gate opens**, then **background** — the home-widget re-render, blocklist
   drift repair (`syncEngineBlocklists()`, also the resume path's heavy leg),
   and the `rules` / `dailyLimit` / `streak` reloads, all fire-and-forget.
   Nothing routes on any of it, so making the user watch it would be pure
   latency. On a non-first run `targets.load()` moves into this phase.

The first-run predicate is captured **before** phase 2, not re-read after it:
`SettingsCubit._commit` emits synchronously, so the seed makes the enabled set
non-empty and a re-read would run the slow leg a second time on the one launch
that can least afford it. Those three cubit reloads live here and **only** here —
`main.dart` deliberately does not `..load()` them at provider construction, which
used to run every one of them twice per cold start (and `RulesCubit.load()` ends
in a resync, so that was two UsageStats reads and two native pushes).

The whole body is wrapped in try/finally, and **the finally opens the gate
regardless**. The per-step guards cover the phases but not the prologue's
`context.read`s or the `gate.update` argument list — a throw there left `ready`
false, which pins every location to `/`, and the splash does not re-run its
post-frame callback, so the spinner was forever. On that path `onboarded` is read
from the repository rather than the cubit that may be what failed: opening the
gate with a default `false` would walk an already-onboarded user back through the
entire first run, a worse outcome than the failure being recovered from.

The order the gate then applies:

```
unsupported  →  onboarding  →  PIN lock  →  permissions  →  home
```

1. `!ready` → `Routes.splash` (nothing routes on unloaded state)
2. `!supported` (`PlatformCapabilities.isBlockingPreviewOnly`) → `Routes.unsupported`
3. `!onboarded` → `Routes.onboarding`
4. `pinLocked` (PIN configured and guards `PinScope.app`) → `Routes.pinLock`
5. `!permissionsOk` (`allRequiredGranted`) → `Routes.permissions`
6. otherwise → `Routes.home`

**"Reset app data" re-enters the splash without restarting the process**, so
`settings_screen.dart` calls `AppGate.reset()` before `context.go(Routes.splash)`.
Without it the gate would still hold the pre-wipe flags, wave the user straight
back to home, and the bootstrap would never run.

### The home shell — `lib/features/dashboard/presentation/home_shell.dart`

`HomeShell` is a two-tab surface (**Dashboard** / **Activity**) over the ambient
gradient, with a frosted floating bottom bar. The former "More" tab now lives in
a right-side `AppDrawer`. Deeper screens (settings, blockers, daily limit,
analytics, content-counter appearance) are reached via routes.

`Routes.blocklist` used to register a *second* `HomeShell` on `/blocklist`,
which is how the two tabs came to share one navigation stack; that constant is
gone and `/home` is the only registration.

**Why no `StatefulShellRoute.indexedStack`, and no per-tab deep link.** Both tabs
are leaves — every drawer destination pushes *above* this shell — so there is no
per-tab back stack for an indexed stack to preserve. It would, however, keep both
tabs alive at once, and `_tab()` deliberately builds **only the active one** so
the floating bar's single `ScrollController` attaches to exactly one scrollable
for hide-on-scroll. A `?tab=` query seam was briefly added and then removed: no
caller anywhere in the app produced such a URL and the gate's redirect returns a
bare `Routes.home`, so the parameter was provably never non-default. Add it back
the day something actually links to a tab.

`DashboardTab` renders its sections in order: `DashboardTopBar` → `_Hero`
(`CommandCenterCard`) → `_ModeSection` (`ModeSelector`) → `_SessionBanners` →
`ProtectionStatusCard` → `BlockerSection`. The house split is that a section
needing cubits stays inline in `dashboard_tab.dart` as a private `_Xxx` widget
while its presentational half lives in `presentation/widgets/`.

Two rebuild/state notes on the dashboard (EVO-014 + polish):

- `ProtectionStatusCard` renders `ServiceStatus.unknown` (the cold-start
  default of `ServiceSnapshot` — the status read simply hasn't answered) as a
  **neutral "Protection Status / Checking…" card**, not the danger "Protection
  off" card; the next refresh (resume/stream) settles it. A scare card that
  cries wolf on every hiccup teaches the user to ignore the real one.
- The `_Hero`'s Conscious countdown uses `context.select` on a **record of the
  four displayed fields** so the 1 Hz Conscious tick doesn't rebuild the whole
  hero, and the Conscious session banner is extracted into a private
  `_ConsciousBanner` widget so that tick rebuilds only that tile.

`ModeSelector` (`presentation/widgets/mode_selector.dart`) is the horizontally
scrolling strip of five mode pills. Each pill is an illustration "coin" over its
label: the mode's `assets/images/illustration/*.png` clipped to a ring-lit circle
— the same artwork its feature-tour step shows. The art is full-colour on an
opaque backdrop, so the circular clip is what turns it into an icon, and the
inactive state dims/shrinks the coin rather than tinting it. Every decode is
capped with `cacheWidth` (the source art is 1024²).

`BlockerSection` (`presentation/widgets/blocker_section.dart`) is the exception
that owns its own data: it renders the App Blocker / Web Blocker pair as two
`BlockerTile`s and reads the live entry counts itself. Both blocker cubits are
screen-scoped — created inside `BlocProvider`s in `app_block_screen.dart` /
`web_block_screen.dart` — so there is nothing to watch from the dashboard. The
section resolves `AppBlockRepository` and `WebBlockRepository` through `sl`
instead, counts the entries with `enabled == true`, and re-reads them when the
user pops back from either blocker screen, so the captions never go stale.

### Glass surfaces — `lib/core/design_system/foundations/`

`GlassContainer` is the one glass primitive; nothing else calls `BackdropFilter`
directly. It clips a squircle (`AppRadius.continuous`) over a backdrop blur, adds
a top-weighted sheen, and lights the edge with a `LiquidGlassBorder`.

**Glass surfaces cast no drop shadow.** Depth comes from the glass itself — the
fill gradient, the sheen, and the lit rim — so cards sit cleanly on the ambient
background instead of on a grey smudge. Don't reintroduce a `BoxShadow` here;
`test/core/design_system/glass_container_test.dart` fails if you do. (A `BoxShadow`
with its `color` omitted defaults to **opaque black**, which is how this
regressed once already.)

`LiquidGlassBorder` is the Apple Liquid Glass / visionOS edge: two stroked paths,
no `saveLayer`, no `MaskFilter`, no shader asset, nothing animated.

- **Rim** — a hairline stroke of `shape.getOuterPath(...)` shaded by a
  `SweepGradient`. The arcs are deliberately asymmetric: a wide, bright key light
  at the top-left (sweep fraction `0.625`) and a tighter, dimmer bounce where
  that light exits again at the bottom-right (`0.125`), falling back to the plain
  hairline token elsewhere. Equal arcs read as a decorative gradient; unequal
  ones read as a lit object. The boosted specular is capped below full opacity —
  an opaque hairline is an outline again.
- **Thickness** — a second stroke inset ~1.2px, lit top-down rather than
  diagonally, so it is a different cue from the corner arcs rather than a fainter
  copy of them.

Because it takes a `ShapeBorder`, squircles, circles, stadiums and any radius all
work with no separate code path. Every colour comes from the `GlassTokens`
extension (`context.glass`), so the edge tracks the live theme and the selected
background; only the alphas belong to the widget, and `intensity` scales them
together.

`liquidEdge` defaults to **true**, so every glass surface in the app gets the lit
edge. `selected` tints the rim with the brand instead of casting a glow shadow.
Set `liquidEdge: false` to fall back to the plain 1px hairline — one painter
cheaper, but visibly flatter.

---

## The native ↔ Dart boundary

The split of responsibility is deliberate:

- **Dart owns** configuration, settings, plans, UI, and all persistence of user
  preferences. It is the control plane.
- **Native owns the hot path**: the AccessibilityService receives a11y events,
  runs detection, applies the active plan/pause gate, blocks, counts content, and
  matches web hosts — all in the main process, off the Dart isolate, so it keeps
  working even when the Flutter UI process is gone.

### One command channel, one event channel

Everything crosses through exactly **two** platform channels (names in
`lib/core/constants/channel_constants.dart`; wired natively in
`android/.../MainActivity.kt`):

| Channel | Direction | Name |
|---|---|---|
| `MethodChannel` | Dart → native (commands) | `com.errorxperts.detoxo/commands` |
| `EventChannel` | native → Dart (stream) | `com.errorxperts.detoxo/events` |

`EngineChannel` (`lib/core/platform_channels/engine_channel.dart`) is the single
low-level wrapper repositories build on. It exposes typed helpers for the command
methods — `pushConfig`, `pushSettings`, `pushWebBlocklist`, the permission
checks/launchers, `performBack` / `killApp` / `lockScreen`, `blockStats`,
`consciousState`, and the content-counter commands (`contentCounterSnapshot`,
`setContentCounterEnabled`, `setContentBubbleEnabled`, `pinContentWidget`,
`refreshContentWidget`, `setCounterStyle`, `installedPackages`). The event stream
is a single broadcast stream whose payloads are demultiplexed by a `type` field:
`serviceStatus`, `blocked`, `webBlocked`, `consciousState`, `reelSessionState`,
`contentCounted` — six types, each with a real native emitter. (The `detection` and
`foregroundChanged` constants listed in an earlier revision were inert and have been deleted;
[18-platform-channel-contracts.md](18-platform-channel-contracts.md) is authoritative.)

The command/event contract is documented in full in the platform-channel
contract doc; the native side of the hot path is in the detection-engine doc.

### Gated off non-Android

`PlatformCapabilities` (`lib/core/platform/platform_capabilities.dart`) is the
single source of truth for "what can this platform do". `EngineChannel` consults
`supportsBlockingEngine` and **no-ops off Android**: command invocations
short-circuit to safe defaults and the event stream is `Stream.empty()`, so
screens render with sane defaults instead of throwing `MissingPluginException`.
On iOS/web the router surfaces `UnsupportedScreen`.

### The native engine is a bound service run as a foreground service

There is **no separate `:as_process`** — the AccessibilityService
(`accessibility/DetoxoAccessibilityService.kt`) runs in the main process. On
connect it promotes itself with `startForeground(...)`
(`FOREGROUND_SERVICE_TYPE_SPECIAL_USE` on API 34+) behind an ongoing status
notification (channel `detoxo_protection_channel`, id `1125`). The OS re-binds
an enabled accessibility service automatically after boot;
`receivers/BootReceiver.kt` (re)arms the protection watchdog
(`receivers/WatchdogJobService.kt` — a 15-min JobScheduler check that posts a
"Protection stopped" notification when the service has been silently killed;
a rebind cannot be forced, so detect + notify is the ceiling). See
[12-analytics-notifications-resilience.md](12-analytics-notifications-resilience.md).

---

## Directory map

### `lib/`

```
lib/
  main.dart                     entry: DI → MultiBlocProvider → MaterialApp.router
  app/
    splash_screen.dart          the brand moment; calls runBootstrap, does not route
    bootstrap.dart              ordered, individually-guarded app-start work
    starter_rule_sync.dart      writes the first run's rule on the grant edge
    unsupported_screen.dart     iOS/web honest "runs on Android" state
  core/                         infra reused by 2+ features
    constants/                  app_constants (EngineTimings) · channel_constants
    di/                         injector.dart — get_it locator `sl`
    navigation/                 app_router.dart · routes.dart · app_gate.dart
    platform/                   platform_capabilities.dart (Android gate)
    platform_channels/          engine_channel.dart (MethodChannel/EventChannel wrapper)
    storage/                    local_store.dart (key-value)
    design_system/  theme/      tokens, foundations, components, glass UI
                                foundations: glass_container · liquid_glass_border
    error/ utils/ widgets/      shared helpers + common widgets
  features/
    blocking/                   CORE: shared(spine) · engine · blocklist · plans
    content_counter/            core · bubble · home_content_counter · appearance
    limits/                     app_blocker · web_blocker · daily_limit
    access_protection/          PIN setup/lock/recovery
    monetization/premium/       entitlement (dev-unlock; no live billing)
    analytics/                  local block-event history
    permissions/                Android permission funnel
    onboarding/ settings/ dashboard/   presentation-only orchestration surfaces
    additional_feature/         app_feedback · showcase_view
```

### `android/app/src/main/kotlin/com/errorxperts/detoxo/`

```
MainActivity.kt                 FlutterFragmentActivity; wires the two channels
accessibility/
  DetoxoAccessibilityService.kt hot path: detect + block + count; status notification
channels/
  CommandHandler.kt             MethodChannel handler (Dart → native)
  DetoxoEventStream.kt          EventChannel stream handler (native → Dart)
engine/
  DetectionConfig.kt            parses Dart-pushed platforms_config.json
  ConfigStore.kt                SharedPreferences "detoxo_engine_prefs"
  ContentCounter.kt · ContentCounterStore.kt   decoupled counting + persistence
  WebBlockEngine.kt · BrowserUrlExtractor.kt    address-bar host blocking
  ServiceEventBus.kt · UsageLadder.kt
overlay/
  ContentCounterBubble.kt       WindowManager overlay bubble (draggable, edge-snap)
widget/
  ContentCounterWidgetProvider.kt · WidgetBitmapRenderer.kt   home-screen widget
admin/
  DetoxoDeviceAdminReceiver.kt  uninstall protection + lockNow (force-lock)
receivers/
  BootReceiver.kt               (re)arms the watchdog job (OS re-binds the a11y service)
  WatchdogJobService.kt         15-min "is protection alive?" check → "Protection stopped" notification
```

---

## Persistence & config at a glance

- **Dart preferences:** `lib/core/storage/local_store.dart` — a simple key-value
  store (not Hive/Drift/Room/ContentProvider). Secrets live in
  `flutter_secure_storage`.
- **Native state:** `SharedPreferences` file `detoxo_engine_prefs` via
  `engine/ConfigStore.kt` (settings/config the service reads cross-process) and
  `engine/ContentCounterStore.kt` (counter totals). Home-widget keys `cc_today` /
  `cc_total`.
- **Config is offline-first:** bundled `assets/config/platforms_config.json` +
  `assets/config/initial_config.json` (`AppConstants.bundledPlatformsConfig` /
  `bundledInitialConfig`). There is no live backend; a remote `ConfigRepository`
  is a documented swap-in.

Detailed treatment lives in the persistence and configuration docs.

---

## Source files

- `README.md`
- `pubspec.yaml`
- `lib/main.dart`
- `lib/app/splash_screen.dart`
- `lib/app/bootstrap.dart`
- `lib/app/starter_rule_sync.dart`
- `lib/core/navigation/app_gate.dart`
- `lib/app/unsupported_screen.dart`
- `lib/core/di/injector.dart`
- `lib/core/navigation/app_router.dart`
- `lib/core/navigation/routes.dart`
- `lib/core/constants/channel_constants.dart`
- `lib/core/platform_channels/engine_channel.dart`
- `lib/core/platform/platform_capabilities.dart`
- `lib/core/design_system/foundations/glass_container.dart`
- `lib/core/design_system/foundations/liquid_glass_border.dart`
- `lib/features/dashboard/presentation/home_shell.dart`
- `lib/features/dashboard/presentation/dashboard_tab.dart`
- `lib/features/dashboard/presentation/widgets/blocker_section.dart`
- `lib/features/dashboard/presentation/widgets/blocker_tile.dart`
- `lib/features/` (feature tree: `blocking`, `content_counter`, `limits`, `access_protection`, `monetization/premium`, `analytics`, `permissions`, `onboarding`, `settings`, `dashboard`, `additional_feature`)
- `tool/check_boundaries.sh`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/MainActivity.kt`
