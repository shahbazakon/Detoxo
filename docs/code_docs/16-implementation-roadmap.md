# Status & Roadmap

The honest "what actually runs in this build vs. what needs your accounts / a follow-up" for
**Detoxo** (`com.errorxperts.detoxo`). Authored from the shipped source, not aspirations.

Bottom line: this is an **Android-only** build whose config is **offline-first** (bundled assets, no
custom backend) with **no live billing/ads**. It does bundle a **Firebase telemetry layer**
(Analytics / Crashlytics / Performance) — the one path that sends data off-device; see
[19-firebase-telemetry.md](19-firebase-telemetry.md). The native detection/block engine is real and
works on a physical device; the network-, account-, and store-dependent layers are deliberately left
as clearly-marked swap-in points. iOS is unsupported (see
[15-ios-cross-platform.md](15-ios-cross-platform.md)).

---

## 1. What works in this build

These are wired end-to-end and enforced by the native engine or Dart runtime — no external service
required.

| Area | Status | Where |
|---|---|---|
| Reel/Short detection + block (AccessibilityService) | **Works on a real device** — 3-stage view-id detection, `PRESS_BACK`/`KILL_APP`/`LOCK_SCREEN`/`NONE` block modes, native throttle/debounce/rate-limit | [03-detection-engine.md](03-detection-engine.md), `DetoxoAccessibilityService.kt` |
| Blocking plans (`blockAll` / `curious`=**Conscious** / `oneReel` / `paused`) + pause window | **Honored by the engine** — `activePlan` gate + `pauseUntil` clock window + Conscious time-bank accountant | [05-plans-pause-conscious.md](05-plans-pause-conscious.md) |
| Web blocklist enforcement | **Wired natively** — `WebBlockEngine` reads the browser address bar in the hot path, matches wildcards, presses Back with per-host debounce, records stats | [06-app-and-web-blocker.md](06-app-and-web-blocker.md), `engine/WebBlockEngine.kt` |
| Custom whole-app blocking | **Wired natively** — `pushAppBlocklist` → `ConfigStore.blockedAppPackages`; the service HOME-bounces a blocked app with toast + vibration, recorded to the shared block counter | [06-app-and-web-blocker.md](06-app-and-web-blocker.md), `DetoxoAccessibilityService.kt` (`onAppBlocked`) |
| Content counter (decoupled from blocking) + bubble + home-screen widget | **Works** — side-effect-free counting pass runs even when blocking is off; drives overlay bubble + `home_widget` | [17-content-counter.md](17-content-counter.md) |
| Blocklist (data-driven) | **Works** — parsed from bundled `assets/config/platforms_config.json`; per-platform enable/disable persisted natively | [02-detection-config-schema.md](02-detection-config-schema.md) |
| PIN lock + biometric/device-credential + retry-lockout ladder + Smart Auto Lock (resume re-lock, FLAG_SECURE Recents privacy) | **Works** — `local_auth` + `flutter_secure_storage`. **No recovery channel by design**; the `000000` dev backdoor was removed, not wired | [08-pin-lock-recovery.md](08-pin-lock-recovery.md) |
| Analytics (block-event history) | **Works, local only** — capped in-memory/JSON block-event buffer (recent ~100); no cloud sink | [12-analytics-notifications-resilience.md](12-analytics-notifications-resilience.md) |
| Firebase telemetry | **Wired** — Analytics (screen views + usage events), Crashlytics, Performance; anonymised, collection on in every build | [19-firebase-telemetry.md](19-firebase-telemetry.md) |
| Persistence | **Works, on-device only** — Dart `local_store` + native `detoxo_engine_prefs` + secure storage + widget keys `cc_today`/`cc_total` | [09-persistence-data-model.md](09-persistence-data-model.md) |
| Config load | **Works, offline** — bundled JSON assets via `ConfigRepositoryImpl`; no live fetch | [10-networking-config-sync.md](10-networking-config-sync.md) |

> Note vs. the top-level `README.md` status table: the README groups "app/web/usage native
> enforcement" as a single follow-up. That is conservative — in the actual code the **web blocklist
> path** and **full-app blocking** are already wired natively (`WebBlockEngine` plus the
> `blockedApps` HOME-bounce branch in `onAccessibilityEvent`). What remains a follow-up is
> **daily-limit / usage enforcement** (see §2).

---

## 2. Native enforcement scope — what is *not* enforced yet

The native engine covers the **reel/short view-id path**, **web host blocking**, and **custom
whole-app blocking**. One limit feature is still UI + persistence in Dart with **no native
enforcement yet**:

| Feature | What exists | What's missing (follow-up) |
|---|---|---|
| **App blocker** (`lib/features/limits/app_blocker`) | **Natively enforced** — `syncAppBlocklist` pushes enabled packages via `pushAppBlocklist`; `ConfigStore.blockedAppPackages` persists them; the service HOME-bounces any blocked app on any event (toast + vibration, shared block counter, protected/self/launcher/systemui skips) | Per-entry `lockAction` / `dailyLimitMinutes` are still unused — every block acts as a HOME bounce |
| **Daily limit** (`lib/features/limits/daily_limit`) | Full UI, quota math, reset logic, Dart persistence, unit-tested | `ConfigStore` has **no daily-limit/usage keys**; native does only permission checks (`hasUsageAccess`), no `UsageStats` polling or quota-triggered block. Needs: usage sampling + a native quota gate |

See [06-app-and-web-blocker.md](06-app-and-web-blocker.md) and
[07-daily-limit-scheduler.md](07-daily-limit-scheduler.md).

---

## 3. Swap-in points (needs your accounts / infra)

Every external dependency is isolated behind a repository or a single config value so it can be
replaced without touching feature code.

### Backend API (config)
- **Config:** `ConfigRepositoryImpl` (`lib/features/blocking/shared/data/repositories/config_repository_impl.dart`)
  reads bundled JSON assets. A remote refresh is a documented swap-in — implement a networked
  `ConfigRepository` and point a base URL at it (README notes `core/config/` as the home for
  base URLs / product ids). No live endpoint is bundled.
- **PIN recovery is deliberately not a swap-in.** The old `_devOtp = '000000'` stub — which
  `validateOtp` accepted against any email, with the code shown to the user — was **removed**.
  A client-side code is a lock bypass, not a recovery, so there is nothing here to wire later.
  Reinstalling is the documented escape hatch. See [08-pin-lock-recovery.md](08-pin-lock-recovery.md).

### Firebase / FCM
- **Telemetry is now bundled.** `android/app/google-services.json`, `lib/firebase_options.dart`, and
  the google-services + Crashlytics Gradle plugins are wired; Analytics, Crashlytics and Performance
  are live (see [19-firebase-telemetry.md](19-firebase-telemetry.md)). Performance runs with **manual
  traces only** — the auto-trace Gradle plugin is omitted (its 1.4.2 release is incompatible with
  AGP 9). Collection is unconditional — a **consent / opt-out gate is the main follow-up** (see §6).
- **Still swap-ins:** FCM push is not bundled, and the local `AnalyticsRepository` block-event buffer
  has no cloud sink (it stays on-device).

### Play Billing / Premium & AdMob — SDKs removed
- `in_app_purchase` and `google_mobile_ads` were **deleted from `pubspec.yaml`**, along with the
  `BILLING` / `AD_ID` permissions and the Google **test** AdMob App ID in the manifest. Nothing
  imported either SDK, but shipping them declared Advertising ID and Billing to Play while the
  in-app FAQ promised "no ads, no ad tracking" — a data-safety contradiction, plus a test ad id in a
  production listing. Re-add deliberately, with real ad units and corrected in-app copy, when
  monetization is actually built. See [11-monetization.md](11-monetization.md) §5.

### Release signing & build — done
- `android/app/build.gradle.kts` loads a real keystore from the gitignored `android/key.properties`,
  registering the signing config **only when that file exists** (an unguarded cast previously broke
  configuration for *all* build types on a fresh clone). Missing keystore → debug signing + a warning.
- `bash tool/dev.sh release` builds the signed `.aab` with `--obfuscate --split-debug-info` and
  refuses to run without the keystore. See [22-play-release.md](22-play-release.md).
---

## 4. Premium, ads & billing — honest state

The README status table shows "Premium gating ✅ via local dev-unlock". In the **current source
that is scaffolding only**, so be precise:

- **No `lib/features/monetization` / premium feature directory exists.** There is no entitlement
  model, no premium gating, and no dev-unlock UI wired into any screen.
- The only premium artifact is a single constant `LocalStore.premiumDevUnlock = 'premium_dev_unlock'`
  in `lib/core/storage/local_store.dart` — **declared but referenced nowhere else** in `lib/`.
- `in_app_purchase` and `google_mobile_ads` are **declared dependencies with registered plugins but
  zero Dart call sites** (no `InAppPurchase`, no `MobileAds.instance.initialize()`, no ad widgets).
- The manifest carries billing/ad-id permissions + the AdMob **test** App ID.

Net: premium, ads, and billing are **dependency- and manifest-level scaffolding**, not a working
feature in this build. Treat monetization as greenfield (repository + entitlement gate + UI) rather
than a swap of existing wiring. See [11-monetization.md](11-monetization.md).

---

## 5. Testing strategy

Three layers, one driver: **`tool/qa.sh`**. Layer 1 is host-only; layers 2–3 need an attached
Android device. The agent-facing runbook is `.claude/skills/detoxo-auto-test/SKILL.md`
(run **`/detoxo-auto-test`**).

| Layer | Command | What it gates |
|---|---|---|
| 1 — static + unit | `bash tool/qa.sh functional` | `dart format`, `flutter analyze`, `flutter test`, `check_boundaries.sh` |
| 2 — real-boot E2E | `bash tool/qa.sh -d <serial> e2e` | `integration_test/app_e2e_test.dart` + screenshots |
| 2b — engine smoke | `bash tool/qa.sh -d <serial> blocking` | service bound; real block is half-manual |
| 3 — performance | `bash tool/qa.sh -d <serial> perf` | `build/qa/metrics.json` vs `baseline.json` |

Artifacts land in `build/qa/` (gitignored via `/build/`).

### Layer 1 — Dart (runs today: `flutter test`)
**26 test files / 240 tests** under `test/` — pure Dart + widget tests, no device needed. Grouped
by where business rules live:

| Area | Tests |
|---|---|
| Domain / settings | `domain_test.dart`, `app_settings_test.dart` |
| Plans & sessions | `plans_pause_curious_test.dart` (pause math + `curious`/Conscious) |
| Access protection | `access_protection_test.dart`, `usage_ladder_test.dart` (retry-lockout ladder) |
| Blocking & limits | `web_blocker_test.dart`, `blocklist_install_filter_test.dart`, `streak_test.dart` |
| Protected apps | `protected_apps_test.dart` (catalog, repo salvage/migration, cubit, fail-closed PIN gate, wire contract) |
| Permissions | `permissions_restricted_settings_test.dart` (ECM / non-Play install path) |
| Content counter | `counter_style_test.dart` |
| Help & upgrade | `help_test.dart`, `app_upgrader_test.dart`, `legal_web_view_test.dart` |
| Dashboard widgets | `blocker_tile_test.dart`, `mode_selector_test.dart` |
| Feedback | `app_feedback_test.dart` |
| Design system | `test/core/design_system/*` (6 files: toggle, glass container, segmented, buttons, avatar, liquid border) |
| Firebase | `test/core/services/firebase/*` (3 files: bloc observer, native event reporter, analytics service) |

`flutter analyze` is clean.

> **`dart format .` was aborting the whole gate (fixed Aug 2026).** It walked
> `build/ios/SourcePackages/`, where the vendored Firebase example packages ship an
> `analysis_options.yaml` whose `include:` resolves outside the checkout; `dart_style` then died
> with `PathNotFoundException`. Because `t_precommit` runs under `set -e`, the gate aborted at
> step 1 and **never reached `flutter analyze` or `flutter test`** — so 83 files of format drift
> and 4 failing `blocker_tile_test.dart` cases accumulated unnoticed. `tool/dev.sh` now formats
> the source trees it owns (`lib test integration_test test_driver`) instead of `.`.

### Layer 2 — on-device integration
`integration_test/` holds four tests plus the shared `qa_walk.dart` helper, all requiring a real
engine (never plain `flutter test`):

| File | Boots app? | Purpose |
|---|---|---|
| `pin_dialog_test.dart` | no — widget subtree + fakes | native `cupertino_native` platform-view layout |
| `pin_setup_flow_test.dart` | no — widget subtree + fakes | PIN setup / turn-off flow on a real engine |
| `app_e2e_test.dart` | **yes — `app.main()`** | splash → onboarding → permissions → home → showcase → drawer walk, theme flip |
| `app_perf_test.dart` | **yes — `app.main()`** | frame timeline over a dashboard scroll (`flutter drive` only) |

`app_e2e_test.dart` is the only thing that exercises the real boot path — `Firebase.initializeApp`,
`configureDependencies()`, Hive, go_router gating and the native MethodChannel. It branches on
whichever screen it lands on, so it is safe against a device that already holds real user data.

Both booting tests share `integration_test/qa_walk.dart` — `settle` / `waitFor` / `waitForAny`,
the screen-marker constants, and `bootApp()`. It sits outside `lib/`, so `package:` cannot reach
it and `always_use_package_imports` forbids the relative import; both files carry a documented
`// ignore:`, which beats two divergent copies of `bootApp()`.

Constraints that shape every on-device test:
- **`pumpAndSettle` never converges.** `GlassScaffold`'s ambient background repeats forever, so
  settle by pumping fixed frames instead (`settle()`).
- **Only one test per file may call `app.main()`.** `configureDependencies()` uses
  `registerSingleton` with no `allowReassignment` and nothing calls `sl.reset()`.
- **`app.main()` hijacks the harness's error handling.** `installGlobalHandlers()` replaces
  `FlutterError.onError` and `PlatformDispatcher.instance.onError` with Crashlytics', and the run
  dies on *"A test overrode FlutterError.onError…"*. `bootApp()` restores both — any new
  real-boot test must use it.
- **`flutter test -d` uninstalls the app when it finishes**, wiping Hive and the accessibility
  grant. Every run therefore starts from a fresh install, which is why the walk branches on the
  screen it lands on and why `perf` re-runs `prep`.
- **`find.text` matches the rendered string** — `SectionHeader` uppercases (`'THEME'`), the nav
  pill is `Semantics(label:)`-only (the dashboard marker is `'Block All'`), and widgets below a
  lazy sliver are never built at all.

### Layer 3 — performance
`bash tool/qa.sh perf` measures cold start (`am start -W`), Dart startup
(`--trace-startup`), the frame timeline (`flutter drive` + `traceAction`), memory
(`dumpsys meminfo`) and release APK size, then diffs `build/qa/metrics.json` against
`baseline.json` via `tool/qa_metrics.py`. All measurement is **profile** builds — debug numbers
are 3–10× off and the ratio is not stable across changes (APK size is the exception and must be
**release**, the only build type that minifies/shrinks). A gate trips only when a delta breaches
**both** a percentage and an absolute floor, so device jitter alone cannot flap it.

Three things the frame-timeline leg requires, each found the hard way:
- **`--no-dds`** — `traceAction` → `enableTimeline` opens its own websocket to the VM Service and
  DDS holds that port, so the run dies with *"Failed to connect to VM Service"* **after** the walk
  has already succeeded.
- **`--keep-app-running`** — `flutter drive`'s exit-time uninstall raced a spawning process and
  took the Android runtime down with it (`JNI FatalError: Failed to mount /data_mirror/…`),
  soft-rebooting the phone mid-suite.
- **`dumpsys meminfo` runs after the drive.** It measures whichever screen the app landed on, and
  that follows stored state — a fresh install sits on `/onboarding`, an onboarded one builds the
  whole dashboard. Reading it earlier made the metric a function of install history: a baseline
  taken on `/onboarding` scored the next run on `/home` as +28.9% memory from a byte-identical
  APK. Re-baseline after any change to this ordering.

### Boundary / architecture check
`tool/check_boundaries.sh` enforces the feature-isolation rule (a feature may import another
feature's public barrel or `domain/`, never its `data/`/`presentation/`).
**Fixed (Aug 2026).** The script used to grep a pre-rebrand package prefix, so it matched nothing
and passed vacuously from the rename onward. It now greps `package:detoxo/` and genuinely enforces
the rule. Repairing it surfaced 12 pre-existing violations, grandfathered in
`tool/boundaries_baseline.txt`; anything new fails the build.

### Native (Kotlin)
- **No instrumented/unit tests are bundled** for the engine. The detection/block hot path is
  validated on a device via `bash tool/qa.sh blocking`, which splits honestly in two:
  - **automated** — `dumpsys accessibility` proves the service is bound and receiving events;
    `pm list packages` proves a target app is present.
  - **manual** — reaching an actual reel needs a logged-in account and a real scroll inside a
    third-party UI that changes weekly, so the script watches `logcat -s DetoxoService:I` for 60 s
    while a human scrolls. Outcomes are `blocked` / `inconclusive` / `skipped` / `unbound`;
    **`inconclusive` is never reported as a pass.**
- **Real reel/short blocking requires a physical device with the target apps installed**
  (Instagram, YouTube, …). On a bare emulator you can verify the service starts, status/config
  parsing, plans, and navigation — but not live blocking, since those apps aren't present.
- `ServiceEventBus.post` drops events when no Flutter engine is attached, so the EventChannel is
  **not** usable as an out-of-process probe — logcat is the only cross-process signal.

---

## 6. Compliance & policy notes

Shipping this app has real Play Store policy obligations. None of these are optional for a store
release.

- **AccessibilityService use + prominent disclosure.** Google Play requires a qualifying use for
  `BIND_ACCESSIBILITY_SERVICE` **plus a prominent in-app disclosure** of what the service does with
  on-screen content. The app ships a disclosure string in
  `android/app/src/main/res/values/strings.xml` (`accessibility_service_description`: it detects
  short-form video and blocks it, "reads on-screen content only to find and block distracting
  feeds; it does not collect or transmit your screen content") and the permission funnel explains
  the grant. Keep the disclosure prominent, accurate, and shown **before** requesting the grant.
- **No foreground service.** The service runs in the **main process** and posts a persistent
  notification (channel `detoxo_protection_channel`, id `1125`) with
  `NotificationManager.notify()`. It deliberately does **not** call `startForeground()`: an
  accessibility service is already bound at foreground-service priority, so the only thing
  `FOREGROUND_SERVICE_SPECIAL_USE` would add is a Play Console declaration and a manual review.
  Same reasoning for `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — the battery step opens the system
  optimisation list instead of the policy-restricted one-tap dialog.
- **Device admin.** `DetoxoDeviceAdminReceiver` (uninstall protection + `lockNow`) is subject to
  device-admin policy and OEM behavior; use it sparingly and disclose it.
- **Overlays.** The content-counter bubble uses `SYSTEM_ALERT_WINDOW` (Display over apps) with a
  `TYPE_APPLICATION_OVERLAY` → `TYPE_PHONE` fallback — its own policy/OEM constraints apply.
- **`QUERY_ALL_PACKAGES` — removed.** `queryLaunchablePackages()` only needs the manifest's
  `<queries>` MAIN entry, so the restricted permission (and its Console declaration) was dropped
  entirely.
- **Restricted settings / ECM.** Android 13+/15+ block the accessibility, overlay and device-admin
  toggles for non-Play installs. Handled in-app with a detection + walkthrough flow;
  `android:isAccessibilityTool` **stays unset** (Detoxo is not an assistive tool — claiming
  otherwise to dodge the gate is a policy violation). See
  [13-onboarding-permissions.md](13-onboarding-permissions.md) §3.4.
- **Data collection disclosure (Play Data safety / GDPR).** The app now sends anonymised usage
  analytics, crash reports, and performance traces to Firebase
  ([19-firebase-telemetry.md](19-firebase-telemetry.md)). This must be declared in the Play **Data
  safety** form and the privacy policy, and — depending on region/consent rules — may require an
  in-app consent or opt-out control, which is **not yet built** (collection is currently
  unconditional). No PII is sent; the user id is a random install UUID.

---

## 7. Known infra follow-ups (grab-bag)

- **Inherited vendor strings in bundled config — done.** `platforms_config.json` `iconUrl`s point
  at bundled local assets. `assets/config/initial_config.json` was rewritten: the inherited
  notification ids, prior-vendor CTA PDF, community link and dead package references, the
  third-party `inhouseNativeAdConfig` promo and the foreign `admobConfig` ad units are all gone.
  `assets/content/pause_countdown_pause_emojis.json` was rebranded too (6 user-visible strings).
  The repo now contains **zero** prior-app / prior-vendor names in any file, folder, asset or doc
  — including the orphaned `android/*.iml` IDE module file, which was deleted.
- **Boundary check package prefix — done.** Repointed at the real package. Fixing it revealed **12
  pre-existing violations** the gate had never caught (it had matched nothing since the rebrand).
  They are grandfathered in `tool/boundaries_baseline.txt` and reported as warnings; anything new
  fails. Most share one root cause — `settings_cubit` is cross-cutting but only reachable through
  `blocking/shared/presentation/`. **Burn the list down.**
- **Telemetry consent / opt-out** — still the main open compliance gap (§6).
- **Release signing** (see §3) — replace debug signing.
- **Backend + OTP + FCM + Billing + real ads** — remaining §3 swap-ins (Firebase telemetry is wired;
  a telemetry consent/opt-out gate is the follow-up).

---

## Source files

- `README.md`
- `pubspec.yaml`
- `tool/check_boundaries.sh`
- `test/domain_test.dart`, `test/app_settings_test.dart`, `test/plans_pause_curious_test.dart`, `test/usage_ladder_test.dart`, `test/access_protection_test.dart`, `test/web_blocker_test.dart`, `test/blocklist_install_filter_test.dart`, `test/counter_style_test.dart`, `test/app_feedback_test.dart`
- `lib/core/storage/local_store.dart`
- `lib/features/blocking/shared/data/repositories/config_repository_impl.dart`
- `lib/features/access_protection/data/repositories/pin_repository_impl.dart`
- `lib/features/analytics/data/repositories/analytics_repository_impl.dart`
- `lib/features/limits/app_blocker/`, `lib/features/limits/daily_limit/`, `lib/features/limits/web_blocker/`
- `lib/features/settings/presentation/settings_screen.dart`
- `lib/main.dart`
- `lib/core/services/firebase/` (Firebase telemetry layer — see [19-firebase-telemetry.md](19-firebase-telemetry.md))
- `android/app/build.gradle.kts`
- `android/settings.gradle.kts`
- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/res/values/strings.xml`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `assets/config/platforms_config.json`, `assets/config/initial_config.json`
