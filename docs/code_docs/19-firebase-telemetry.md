# Firebase Telemetry (Analytics · Crashlytics · Performance)

Detoxo ships a **Firebase telemetry layer**: usage analytics, crash reporting, and performance
traces. This is the one part of the app that sends data off-device, so it is deliberately isolated
in `lib/core/services/firebase/`, kept behind interfaces, and governed by strict privacy rules (§6).

> **This changes the app's data posture.** Earlier builds were fully offline with *nothing* leaving
> the phone. With this layer wired, anonymised usage/crash/performance data is sent to Firebase.
> The **local block-event history** (`AnalyticsRepository`,
> [12-analytics-notifications-resilience.md](12-analytics-notifications-resilience.md)) is a
> *separate* on-device buffer and still never uploads — don't conflate the two. User-facing
> disclosure lives in [`../info_docs/04-faqs.md`](../info_docs/04-faqs.md) and
> [`../info_docs/03-permissions-explained.md`](../info_docs/03-permissions-explained.md).

Related: [14-flutter-package-map.md](14-flutter-package-map.md) (deps),
[18-platform-channel-contracts.md](18-platform-channel-contracts.md) (native events the reporter
consumes), [16-implementation-roadmap.md](16-implementation-roadmap.md) (status).

---

## 1. Layout & boundary

```
lib/core/services/firebase/
  firebase.dart                                # public barrel — import this, not the subfolders
  firebase_services.dart                       # FirebaseServices facade (startup wiring)
  analytics/
    analytics_service.dart                     # AnalyticsService interface + FirebaseAnalyticsService
    analytics_events.dart                      # AnalyticsEvent + AnalyticsParam name constants
    firebase_bloc_observer.dart                # FirebaseBlocObserver (global Bloc.observer)
    native_event_reporter.dart                 # FirebaseNativeEventReporter (native → analytics)
  crashlytics/
    crash_reporting_service.dart               # CrashReportingService interface + Firebase impl
  performance/
    performance_service.dart                   # PerformanceService interface + Firebase impl
```

Each service is an **interface → Firebase impl** pair, registered in
[`core/di/injector.dart`](../../lib/core/di/injector.dart) as a lazy singleton, matching the app's
"interfaces for testability" convention. The Firebase SDK instance is injected via a constructor
default (`{FirebaseAnalytics? analytics} : _analytics = analytics ?? FirebaseAnalytics.instance`) so
tests pass a mock. Living under `lib/core/**`, the layer is freely importable by any feature.

---

## 2. Services

| Service | Backing | Key surface |
|---|---|---|
| `AnalyticsService` | `FirebaseAnalytics` | Semantic methods (`logPlanChanged`, `logBlockingToggled`, `logPauseStarted/Ended`, `logBlockTriggered`, `logReelsCounted`, `logWebBlocked`, `logBlockScreenAction`, `logOnboardingStep`, `logScreenView`, `setUserId`), plus `navigatorObserver` (a `FirebaseAnalyticsObserver`). No raw `logEvent` is exposed — the event vocabulary is enforced in one place. |
| `CrashReportingService` | `FirebaseCrashlytics` | `recordError(error, stack, {reason, fatal})`, `setKey`, `setUserId`, `log`, `setCollectionEnabled`, and a **static** `installGlobalHandlers()`. |
| `PerformanceService` | `FirebasePerformance` | `setCollectionEnabled`, `traceAsync<T>(name, action)` (always stops the trace, even on throw). |

Event and parameter names are constants in `analytics_events.dart` (`AnalyticsEvent.*`,
`AnalyticsParam.*`) so nothing uses a magic string, and names stay within Firebase's rules
(`[a-zA-Z][a-zA-Z0-9_]*`, ≤40 chars, no reserved prefix).

### The onboarding funnel

`onboarding_step { step, direction }` fires on every first-run step change.
`step` is the `OnboardingStepId` wire token (`WELCOME` … `PERMISSIONS`);
`direction` is `ENTER` (first render or a resume onto a saved step), `FORWARD` or
`BACK`.

Both halves are load-bearing rather than decorative. Without the `ENTER` event
the first step never fires at all, so welcome→survey drop-off — the most valuable
number in the funnel — has no denominator. Without `direction`, a Back tap is the
same `advance` call as a Next tap and inflates every step total by an unknown
amount.

**No answer ever leaves the device.** Not the name, not the screen-time band, not
the picked feeds — only the two enum tokens above. The record that holds those
answers is also excluded from Android backup (see
[24-protected-apps.md](24-protected-apps.md)).

---

## 3. Startup wiring (`main.dart`)

Order matters — crash handlers install *before* DI so init-time crashes are caught:

```dart
WidgetsFlutterBinding.ensureInitialized();
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
CrashReportingService.installGlobalHandlers();   // FlutterError.onError + PlatformDispatcher.onError
// … system chrome …
await configureDependencies();
Bloc.observer = FirebaseBlocObserver(sl<AnalyticsService>(), sl<CrashReportingService>());
await FirebaseServices.start(sl);
runApp(const DetoxoApp());
```

`installGlobalHandlers()` (static) routes `FlutterError.onError` →
`recordFlutterFatalError` (after `FlutterError.presentError`, so the console
still shows the error) and `PlatformDispatcher.instance.onError` →
`recordError(fatal: true)`. Both are guarded by a **5-minute per-error
dedupe** (keyed on the error string's hash): a repeating per-frame failure —
e.g. a build/layout error loop — must not record at 60fps, because each
report copies its full stack onto the Java heap and the flood OOM-killed the
app on-device (2026-08-17). The first occurrence is always recorded.

`FirebaseServices.start(sl)` (in `firebase_services.dart`) does the rest, once:
1. `setCollectionEnabled(true)` on all three services. **Collection is on in every build** (no
   `kReleaseMode` gate) — debug runs also report, so events land in the console during development.
2. **Anonymous install id** — reads `StoreKeys.installId` from `LocalStore`, generating a random
   `Uuid().v4()` on first run, and sets it as the Analytics **and** Crashlytics user id. It is a
   random per-install token, never anything derived from the device or user.
3. Bridges the logging seam: `AppLogger.onError = (msg, err, stack) => crash.recordError(err ?? msg,
   stack, reason: msg)` — so every `AppLogger.e(...)` becomes a non-fatal Crashlytics report, with
   no Firebase dependency inside `core/utils/app_logger.dart`.
4. Starts `FirebaseNativeEventReporter` (§5).

---

## 4. Event capture — the global `BlocObserver`

`FirebaseBlocObserver` is the single seam that turns cubit activity into telemetry, so **no feature
imports Firebase**. It is installed as `Bloc.observer`, sees every cubit, and:

- **`onChange`** matches on the *state type* `AppSettings` (the app's central settings/plan/pause
  state machine — it imports the `domain` entity, never a Cubit class) and diffs prev→next:

  | Transition | Analytics event | Crashlytics key |
  |---|---|---|
  | `activePlan` changed | `plan_changed { plan }` | `plan` = `BlockingPlan.wire` |
  | `masterEnabled` changed | `blocking_toggled { enabled }` | `master_enabled` |
  | `pauseSession` null→set | `pause_started { duration_min }` | — |
  | `pauseSession` set→null | `pause_ended` | — |

  (The `plan` analytics param uses `BlockingPlan.name` e.g. `curious`; the Crashlytics key uses the
  wire token `CURIOUS`. **Conscious** is the UI label for that plan.)

- **`onError`** forwards every uncaught cubit error to `recordError` with the cubit type as
  `reason`.

Screen views come from two places: the `FirebaseAnalyticsObserver` added to `GoRouter.observers` in
[`core/navigation/app_router.dart`](../../lib/core/navigation/app_router.dart) logs `screen_view` on
every route push; the `HomeShell` bottom-nav tabs don't change the route, so they call
`sl<AnalyticsService>().logScreenView(label)` manually on tab select.

---

## 5. Native-event reporter

`FirebaseNativeEventReporter` holds one persistent subscription to
[`EngineChannel.events()`](../../lib/core/platform_channels/engine_channel.dart) — started at boot by
`FirebaseServices.start` — so native events are captured regardless of which screen is open (unlike
the screen-scoped cubits). It switches on the event `type`
([`ChannelEvents`](../../lib/core/constants/channel_constants.dart)):

| Native event | Analytics | Crashlytics keys |
|---|---|---|
| `blocked` `{platformId, mode, today, total}` | `block_triggered { platform, mode }` | `blocks_today`, `blocks_total` |
| `contentCounted` | `reels_counted { count }` — **batched** (§below) | — |
| `webBlocked` `{host, mode, …}` | `web_blocked { mode }` — **host omitted** (§6) | — |
| `blockScreenAction` `{action, referenceType, referenceId, preview}` | `block_screen_action { action }` — **referenceId omitted** (a host / package), **preview walls skipped** | — |
| `nudgeShown` `{package, elapsedMs, thresholdMs}` | `nudge_shown { duration_min }` — **package omitted**, and `elapsedMs` too: only the threshold band the user configured is sent | — |

**Reel batching:** short videos count at high frequency, so instead of one event per reel the
reporter accumulates and flushes an aggregate `reels_counted { count }` after **25 reels** or **30 s**
(`_reelFlushThreshold` / `_reelFlushInterval`), whichever first; `dispose()` flushes any remainder.

---

## 6. Privacy guardrails

Detoxo is a privacy-focused app, so telemetry params are constrained to non-identifying data:

- **Never sent:** PIN secrets, recovery OTP, emails, **blocked/visited hostnames**, installed-package
  lists, or any on-screen content.
- `web_blocked` logs only the block `mode` — the `host` from the native event is **intentionally
  dropped** (browsing targets are private).
- `block_triggered` logs the platform *category* (`youtube`, `instagram`), never per-URL data.
- Reels are reported as aggregate counts, never per-video.
- The user id is a random install UUID (§3), not a device/user identifier.

When adding an event, keep values to enums/counts/durations — no free-form user data.

---

## 7. Native / build configuration

- **Deps** ([`pubspec.yaml`](../../pubspec.yaml)): `firebase_core ^4.11.0`,
  `firebase_analytics ^12.4.3`, `firebase_crashlytics ^5.2.4`, `firebase_performance ^0.11.4+3`
  (`uuid` — already present — is now wired for the install id).
- **Config files:** `lib/firebase_options.dart` (FlutterFire), `android/app/google-services.json`,
  `ios/Runner/GoogleService-Info.plist`, `firebase.json`.
- **Gradle plugins** — declared in [`android/settings.gradle.kts`](../../android/settings.gradle.kts)
  and applied in [`android/app/build.gradle.kts`](../../android/app/build.gradle.kts):
  `com.google.gms.google-services` (4.3.15) and `com.google.firebase.crashlytics` (3.0.3). The
  Firebase **Performance Gradle plugin is intentionally not applied** — its current release (`1.4.2`)
  uses the removed `com/android/build/api/transform/Transform` API and fails under this project's
  Android Gradle Plugin 9.x. Performance therefore runs **without automatic traces**: only manual
  traces via `PerformanceService.traceAsync` / `newTrace` are collected (currently `load_block_targets`
  in [`TargetsCubit.load()`](../../lib/features/blocking/blocklist/presentation/targets_cubit.dart)).
  Re-add the plugin once a release compatible with AGP 9 ships.
- **iOS:** `DefaultFirebaseOptions.currentPlatform` returns valid iOS config so init works there, but
  the app is unsupported on iOS ([15-ios-cross-platform.md](15-ios-cross-platform.md)) — telemetry
  there is inert in practice.

---

## 8. Testing

`test/core/services/firebase/` (mocktail + `flutter_test`):

- `firebase_bloc_observer_test.dart` — drives `onChange` with two `AppSettings` (plan / master /
  pause) and asserts the mapped analytics calls + Crashlytics keys; `onError` → `recordError`.
- `native_event_reporter_test.dart` — a fake `EngineChannel` stream emits `blocked` /
  `contentCounted` ×N / `webBlocked`; asserts calls, the host omission, and the 25-reel batch flush.
- `analytics_service_test.dart` — a mock `FirebaseAnalytics` verifies semantic methods map to the
  right event name + params.

---

## 9. What is / isn't shipped

| Capability | Status |
|---|---|
| Firebase Analytics — screen views + semantic usage events | Shipped (collection on in all builds) |
| Firebase Crashlytics — fatal handlers, cubit errors, `AppLogger.e` non-fatals, context keys | Shipped |
| Firebase Performance — **manual** `load_block_targets` trace (auto-trace Gradle plugin omitted: AGP-9 incompatible) | Shipped (manual traces only) |
| Anonymous install-id user grouping | Shipped |
| Consent gating / opt-out UI for telemetry | **Not built** — collection is unconditional (follow-up if Play data-safety / GDPR consent is required) |
| Cloud sink for the local block-event `AnalyticsRepository` | Still not wired — that buffer remains on-device (doc 12) |

---

## Redaction at the Crashlytics bridge

`AppLogger.onError` forwards a *message and an error object* to
`crash.recordError`. That object is the one thing in the app that crosses the
network boundary without being written for the wire, and `FormatException`
carries a ~78-character window of **the string it failed to parse**. Five
repositories log a decode failure as `AppLogger.e(msg, e)`, and the blobs are
the user's own data — the protected-apps list, per-app screen time, the rules'
blocked hosts and packages, app settings.

`FirebaseServices.offDevice` therefore reduces a `FormatException` to its type,
message and offset before it is recorded; everything else passes through
untouched, because the leak is specific to exceptions that carry their input.
Local `debugPrint` keeps the full detail — only the uploaded path is scrubbed.
Pinned by `test/crash_redaction_test.dart`, which asserts both that the raw
exception leaks and that the redacted one does not.

## Source files

- `lib/core/services/firebase/firebase.dart`
- `lib/core/services/firebase/firebase_services.dart`
- `lib/core/services/firebase/analytics/analytics_service.dart`
- `lib/core/services/firebase/analytics/analytics_events.dart`
- `lib/core/services/firebase/analytics/firebase_bloc_observer.dart`
- `lib/core/services/firebase/analytics/native_event_reporter.dart`
- `lib/core/services/firebase/crashlytics/crash_reporting_service.dart`
- `lib/core/services/firebase/performance/performance_service.dart`
- `lib/core/utils/app_logger.dart`
- `lib/core/storage/local_store.dart`
- `lib/core/di/injector.dart`
- `lib/core/navigation/app_router.dart`
- `lib/features/dashboard/presentation/home_shell.dart`
- `lib/features/blocking/blocklist/presentation/targets_cubit.dart`
- `lib/main.dart`
- `lib/firebase_options.dart`
- `pubspec.yaml`
- `android/settings.gradle.kts`
- `android/app/build.gradle.kts`
- `android/app/google-services.json`
- `test/core/services/firebase/firebase_bloc_observer_test.dart`
- `test/core/services/firebase/native_event_reporter_test.dart`
- `test/core/services/firebase/analytics_service_test.dart`
