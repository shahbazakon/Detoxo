# M6 — Onboarding step machine + shell/navigation rework

- Status: **shipped** — engineering docs [13-onboarding-permissions.md](../code_docs/13-onboarding-permissions.md) (M6.1) and [01-overview-architecture.md](../code_docs/01-overview-architecture.md) §3–§4 (M6.2). Seven deliberate deviations, recorded below.

> ### Deviations from this plan, as built
>
> The plan was written before M3 shipped and before the shell's constraints were re-read. What
> was actually built differs in seven places, each verified against the source:
>
> | This doc says | Built instead | Why |
> |---|---|---|
> | `StatefulShellRoute.indexedStack` | `HomeShell` keeps its `setState` tabs; `/home?tab=` deep link | `home_shell.dart` builds **only** the active tab so the floating bar's single `ScrollController` attaches to exactly one scrollable. `indexedStack` keeps both alive and breaks that. Both tabs are leaves — every drawer destination pushes *above* the shell — so per-tab back stacks buy nothing today. |
> | `abstract class AppInitializer` + `sl<List<AppInitializer>>()` | An ordered step list in `bootstrap.dart` looping the existing `guardedSync` | `guardedSync` already *is* the never-block-start contract. An interface with an `order` int, a file per step and the repo's first DI collection registration, for a fixed sequence, is abstraction with one shape. Adding a step is a one-line list edit either way. |
> | `Say/AskText/AskChips<E extends Enum>` sealed script | A non-generic `OnboardingQuestion` table, for the survey step only | Only the survey is script-shaped; projection needs arithmetic, selection needs `TargetsCubit`, permissions is an existing screen. A `const` list of `AskChips<E>` erases to `dynamic` in the walker anyway. |
> | 7 steps including `selfDescription` | 6 steps; `selfDescription` dropped | Nothing consumed it — no rule, no copy, no analytics. Every surviving answer drives something. |
> | `Routes.pause` / `Routes.curious` "get real routes" | **Deleted** | Pause and Conscious are dashboard *modes*, not destinations; no screen existed to route to. `unsupported` genuinely was registered — `UnsupportedScreen` had been a compiled orphan. |
> | `sheet_result_bus.dart` | **Not built** | `GlassBottomSheet.show<T>()` already returns `Future<T?>`. A keyed result registry solves a problem this app does not have. |
> | `PlatformCapabilities.isSupported` | `PlatformCapabilities.isBlockingPreviewOnly` | `isSupported` does not exist. |
>
> Two claims in this doc were already stale when it was read: the `onboarding_screen.dart →
> daily_limit_cubit.dart` baseline entry it names as a burn-down candidate had already been
> burned down, and the route count is 29 declared / 26 registered, not 27. The baseline went
> from **7 entries to 0** anyway — exporting `SettingsCubit`, `TargetsCubit` and `BlockAppTile`
> from the blocking barrel cleared every remaining entry and removed the cause of the
> `onboarding → splash` round-trip hack in one edit.
- Source: [D2 Onboarding](../suggestion_docs/flutter-migration/D-insights-engagement/D2-onboarding.md) (adopt) · [D3 Hub Shell](../suggestion_docs/flutter-migration/D-insights-engagement/D3-hub-shell-and-navigation.md) (architecture only)
- Feature areas: `lib/features/onboarding/`, `lib/core/navigation/`, `lib/app/`
- Effort: **L** (a rewrite of onboarding plus a router restructure; both touch app start)
- Blocked by: M0.1, M3 (the starter rule) · Blocks: nothing

Two changes that share a seam: what happens between launching the app and being protected.

---

## M6.1 — Onboarding

### Why now

Today's onboarding is **5 informational PageView screens** that capture exactly one value: the
daily-limit dial (15 min – 5 h, 15-minute steps, default 90). There is no survey, no goal, no
problem-app selection, and — the load-bearing gap — **no persisted position**. Kill the app on
page 4 and it restarts at page 1.

The bigger gap is what onboarding *produces*. A user finishes it with a daily limit and nothing
else: no rule, no blocklist beyond defaults, no reason. The app's first act of protection happens
whenever they later find the blocklist screen on their own.

### What the user gets

A conversational first run that asks a handful of things worth asking, remembers the answers as
they are given, resumes exactly where it left off after a crash or a reboot, and **ends with a
working rule already in place** — so the first thing that happens after granting accessibility is
that Detoxo does something.

### Algorithm & control flow

A **linear, persisted step machine**. Three properties carry the whole design:

```
enter():
    row = store.read(StoreKeys.onboardingProgress) ?? seed(step: welcome)
    route(row.step)                              // RESUME, always — never restart

advance(next):
    store.write(row.copy(step: next))            // (1) PERSIST FIRST
    navigate(next)                               //     then navigate

answer(field, value):
    store.write(row.copy(field: value))          // (2) PER-ANSWER WRITE, never batched

onAccessibilityGranted():
    createStarterRule(row.selection, row.goal)   // (3) rule created AT GRANT TIME
    advance(completed)
    go(home)
```

1. **Persist before navigating.** A crash between the write and the push resumes at the *next*
   step, which is a harmless replay. The reverse order loses the step.
2. **Write each answer as it is given.** Batching at the end means a user who abandons at the last
   question is a user whose answers never existed.
3. **Create the starter rule at grant time, not at selection time.** The rule is written the moment
   enforcement becomes *possible*. Writing it at selection leaves a rule that silently does nothing
   for however long the user hesitates over the accessibility screen — and if they never grant it,
   a rule that does nothing forever.

Steps (7, trimmed from D2's set; the school-invite branch is dropped entirely):

| Step | Purpose |
|---|---|
| `welcome` | What Detoxo is, in one screen |
| `survey` | Name, current screen time band, what matters most, self-description |
| `projection` | The multi-year cost, computed from the screen-time band |
| `selection` | Pick the feeds/apps to protect — **requires ≥ 1** |
| `commitment` | A summary keyed to the chosen goal |
| `permissions` | Accessibility + overlay; the hard gate |
| `completed` | Never shown again |

### Script as data

D2's best idea, and the reason its onboarding is cheap to change:

```dart
sealed class OnboardingStep { }
class Say      extends OnboardingStep { final String textKey; }
class AskText  extends OnboardingStep { final String promptKey, field; }
class AskChips<E extends Enum> extends OnboardingStep {
  final String promptKey, field; final List<E> options;
}

const firstRunScript = <OnboardingStep>[ Say(...), AskText(...), AskChips(...) ];
```

The controller walks the list; the screen renders it. **Adding a question is a list edit**, not a
new widget, a new state field, and a new navigation edge. Given how often onboarding copy churns
before launch, this is the difference between a day and an hour per change.

### Data model

Hive, key `StoreKeys.onboardingProgress`. Enums as **stable name strings**:

```jsonc
{
  "step": "survey",
  "name": null,
  "screenTimeBand": "BETWEEN_3_AND_4H",
  "mattersMost": "FOCUS",
  "selfDescription": null,
  "selection": { "platforms": ["ig_reels"], "apps": [] },
  "dailyLimitMinutes": 90,
  "startedAtMs": 1756742400000
}
```

Enum vocabularies (from D2, trimmed): `ScreenTimeBand` 7 values
(`LESS_THAN_1H … OVER_7H`, `DONT_KNOW`); `MattersMost` 5 (`FOCUS`, `SLEEP`, `PRESENT`, `MENTAL`,
`OTHER`); `SelfDescription` 10. `OnboardingStepId` 7, as tabled above.

### The starter rule

`createStarterRule` writes **one** M3 rule from the survey, so the mapping is legible and testable:

| `mattersMost` | Rule |
|---|---|
| `SLEEP` | Schedule, daily 22:00–07:00, over the selection (exercises the overnight-wrap path) |
| `FOCUS` | Schedule, Mon–Fri 09:00–17:00, over the selection |
| `PRESENT` / `MENTAL` / `OTHER` | Time limit, 30 min/day, over the selection, `lockPeriod: END_OF_DAY` |

Plus the existing daily-limit dial value, migrated onto its own rule by M3.

### Channel delta

**None.** Onboarding drives the existing permission commands.

---

## M6.2 — Shell and navigation

### Why now

Three concrete defects, all visible in ~150 lines:

1. **Dead route constants.** `Routes.pause`, `Routes.curious` and `Routes.unsupported` are declared
   in [`routes.dart`](../../lib/core/navigation/routes.dart) and registered in
   [`app_router.dart`](../../lib/core/navigation/app_router.dart) **nowhere**
   (`grep -c 'Routes.pause' app_router.dart` → 0, same for the other two). Navigating to any of
   them fails at runtime.
2. **Gating is imperative and lives in a screen.** `splash_screen.dart`'s `_bootstrap()` loads
   state then chains `context.go(...)` through onboarding → PIN → permissions → home. Every new
   gate is another branch in one method, in a widget, off the router.
3. **Flat routes, no shell.** `Routes.home` and `Routes.blocklist` both build `HomeShell`, so the
   two tabs share a navigation stack. Deep-linking into a tab, or preserving per-tab scroll and
   history, is not expressible.

Bootstrap has the same shape: `main.dart` wires an 11-cubit `MultiBlocProvider` and a fixed
sequence inline. Adding an initializer means editing the app root.

### What the user gets

Nothing directly — this is structural. Indirectly: per-tab back stacks that behave, working
deep links, and a bootstrap where M0–M5's initializers slot in without touching the shell.

### Source: taken and dropped

**Taken** — three ideas: `StatefulShellRoute.indexedStack` for per-tab stacks; an **ordered
`AppInitializer`** seam so a new bootstrap step is a new class; and a **keyed sheet-result bus** so
a sheet can return a value to whoever opened it.

**Dropped** — D3's 51 typed route classes, its auth/school/referral/migration routes, its 14
coordinators, and its Superwall / Firebase App Check / FCM / heartbeat / attribution bootstrap
phases. Detoxo has 27 routes and no backend; importing a 53-destination graph would be pure cost.

### Algorithm & control flow

```dart
abstract class AppInitializer {
  int get order;                     // sorted ascending; ties keep declaration order
  Future<void> init();
}

// lib/app/bootstrap.dart
Future<void> bootstrap() async {
  final inits = sl<List<AppInitializer>>()..sort((a, b) => a.order.compareTo(b.order));
  for (final i in inits) {
    try { await i.init(); }
    catch (e, s) { sl<CrashReportingService>().recordError(e, s); }   // never block start
  }
}
```

One initializer failing must not stop app start. That is the whole reason the seam exists — today
a throw anywhere in `main()`'s inline sequence is a launch failure.

Gating moves off the splash screen and into a **router `redirect`**, so it is declarative and one
place:

```dart
redirect: (context, state) {
  if (!onboardingComplete) return Routes.onboarding;
  if (pinLockRequired)     return Routes.pinLock;
  if (!requiredPermissionsGranted) return Routes.permissions;
  return null;
}
```

`unsupported` becomes a real route reached by the same redirect when
`PlatformCapabilities.isSupported` is false — which is what the constant was always for.

### Module layout

```
lib/app/
├── bootstrap.dart            # ordered AppInitializer runner
└── initializers/{firebase,engine_sync,resume_sync,rules_push,…}_initializer.dart

lib/core/navigation/
├── routes.dart               # unchanged shape; the 3 dead constants get real routes
├── app_router.dart           # StatefulShellRoute.indexedStack + redirect gating
└── sheet_result_bus.dart     # requestKey -> Completer registry
```

### Reuse map

| Existing | Take |
|---|---|
| `lib/app/engine_sync.dart`, `lib/app/app_resume_sync.dart` | Already initializer-shaped; they become the first two `AppInitializer`s with no logic change |
| `splash_screen.dart` `_bootstrap()` | The gate order — move it, do not redesign it |
| `PlatformCapabilities` | The `unsupported` redirect condition |
| `lib/features/dashboard/presentation/home_shell.dart` | The existing 2-tab shell and drawer; `indexedStack` wraps it rather than replacing it |
| `lib/core/design_system/components/overlays.dart` | The existing sheet components the result bus wires into |
| `showcaseview` (declared, 7-step tour) | The existing coach-mark tour — the new onboarding must not duplicate it |

---

## Risks & ceilings

- **Onboarding is the highest-risk surface to rewrite**, because a bug there is invisible to
  existing users and fatal for new ones. Ship it behind the existing `onboardingComplete` flag so
  current users never re-enter it, and test a cold install on a real device before merge.
- **Router rework touches app start.** Do M6.2 as its own commit, separate from M6.1, so a
  regression bisects cleanly.
- `ponytail: gating is a single redirect closure reading three cubits; a fourth gate makes it a
  chain worth extracting into a policy object.`
- **Do not add a route for every sheet.** The result bus exists so sheets stay sheets.
- **Migration.** Existing users have no `onboardingProgress` record. Absent record + the existing
  completion flag set ⇒ `completed`. Test that path explicitly; getting it wrong re-onboards the
  entire installed base.

## Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] Every constant in `routes.dart` resolves to a registered route — assert it in a test that
      iterates the constants, so this class of bug cannot come back
- [ ] Kill the app at each onboarding step; relaunch resumes at that step
- [ ] An existing user with the completion flag set never sees onboarding
- [ ] Completing onboarding creates exactly one starter rule, and only after accessibility is
      granted
- [ ] Each tab keeps its own back stack; the system back button pops within the tab first
- [ ] An initializer that throws does not block app start and is reported to Crashlytics
- [ ] `pubspec.yaml` unchanged (`go_router` already supports `StatefulShellRoute`)
- [ ] `tool/boundaries_baseline.txt` line count ≤ 8 — note the baseline's existing
      `onboarding_screen.dart → daily_limit_cubit.dart` entry is a **burn-down candidate** here:
      route the daily limit through the M3 rule seam instead and the line goes away
- [ ] Device sanity: cold install → full onboarding → protected without touching settings
- [ ] `/docs-sync` — 01, 13, plus `info_docs/02`

## Target files

**New** — `lib/app/bootstrap.dart` · `lib/app/initializers/**` ·
`lib/core/navigation/sheet_result_bus.dart` ·
`lib/features/onboarding/domain/**`, `data/**` · `test/onboarding_resume_test.dart` ·
`test/routes_registered_test.dart`

**Edited** — `lib/main.dart` · `lib/app/splash_screen.dart` (gating removed) ·
`lib/core/navigation/{routes,app_router}.dart` ·
`lib/features/onboarding/presentation/onboarding_screen.dart` (rewritten as a script walker) ·
`lib/core/storage/local_store.dart` (+`StoreKeys.onboardingProgress`) · `lib/core/di/injector.dart`
