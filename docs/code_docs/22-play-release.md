# Play Store Release & Policy

How to build, sign and submit Detoxo, and the declaration text Play review asks for.
Detoxo touches three surfaces Google scrutinises — **Accessibility API**, **device
admin**, and **overlays** — so the submission needs prepared answers, not improvised ones.
It deliberately declares no foreground-service or battery-exemption permission (§5).

Related: [16-implementation-roadmap.md](16-implementation-roadmap.md) (§6 compliance),
[19-firebase-telemetry.md](19-firebase-telemetry.md) (what is collected),
[13-onboarding-permissions.md](13-onboarding-permissions.md) (disclosure + restricted settings).

---

## 1. Standing decisions (do not "fix" these later)

| Decision | Why |
|---|---|
| **`android:isAccessibilityTool` stays unset** in `res/xml/accessibility_service_config.xml` | Setting it `true` suppresses Android's restricted-settings gate and changes how Play classifies the app — but it asserts Detoxo is an assistive tool for users with disabilities. It isn't. Claiming it is a policy violation and an app-removal risk. The gate is handled in-app instead (§6). |
| **No `QUERY_ALL_PACKAGES`** | `CommandHandler.queryLaunchablePackages()` only calls `queryIntentActivities(MAIN + LAUNCHER)`, which the manifest's `<queries>` block already covers. Declaring a restricted permission that buys nothing invites a Console declaration and a review question. |
| **No ads / IAP SDKs** | Nothing imports them. Shipping them declared Advertising ID and Billing to Play while the in-app FAQ promises "no ads, no ad tracking" — a direct data-safety contradiction. Re-add with the copy fixed when monetization is actually built. |
| **`AD_ID` and the AdServices permissions are stripped** with `tools:node="remove"` | Firebase Analytics (`play-services-measurement-api`) merges them in. Analytics works fine without the advertising ID, and removing them keeps the data-safety form consistent with the in-app claim. **Re-verify after any Firebase version bump** — see §4. |
| **No PIN recovery channel** | With no backend, any code the client could accept is a lock bypass, not a recovery. See [08-pin-lock-recovery.md](08-pin-lock-recovery.md). |

---

## 2. Build the upload artifact

```bash
bash tool/dev.sh release
```

Which runs, after checking `android/key.properties` exists:

```bash
flutter clean && flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```

Outputs:

| Path | Upload to |
|---|---|
| `build/app/outputs/bundle/release/app-release.aab` | Play Console → the release track |
| `build/app/outputs/mapping/release/mapping.txt` | Play Console (deobfuscation file) — R8/Kotlin frames |
| `build/symbols/` | `flutter symbols upload` — Dart frames |

**Both** symbol sets are needed. `--obfuscate` without them makes every Crashlytics
report unreadable, and Crashlytics is live in this build.

Signing: `android/app/build.gradle.kts` loads `android/key.properties` (gitignored) and
**falls back to debug signing with a warning if it is absent**, so a fresh clone still
builds. A debug-signed bundle is rejected by Play — `tool/dev.sh release` fails fast
rather than producing one.

Version comes from `pubspec.yaml` `version: <name>+<code>`. Bump the `+code` on every
upload; Play rejects a reused versionCode. `lib/core/constants/app_constants.dart`
mirrors the build-name — bump both.

---

## 2a. Artifact size

**The `.aab` file size is not the download size.** Roughly half the bundle is
`BUNDLE-METADATA` — the R8 `proguard.map` plus per-ABI native debug symbols produced
by `--obfuscate --split-debug-info`. Play strips all of it before delivery. Never
report the `.aab` byte count as a user-facing number.

### Current baseline (measured, versionCode 2)

| | Value |
|---|---|
| `.aab` on disk | 67,607,969 B (of which 35,049,376 B is BUNDLE-METADATA) |
| **Play download, arm64-v8a** | **13,507,641 – 13,692,200 B** |
| Play download, armeabi-v7a | 13,114,336 – 13,298,902 B |
| Play download, x86_64 | 13,713,955 – 13,898,515 B |

Measure it — do not estimate:

```bash
brew install bundletool
bundletool build-apks --bundle=build/app/outputs/bundle/release/app-release.aab \
  --output=/tmp/detoxo.apks --mode=default
bundletool get-size total --apks=/tmp/detoxo.apks --dimensions=ABI
```

Play Console → *App bundle explorer* → **Download size** is the final authority.

### Composition of what ships (compressed bytes in the bundle)

| Bytes | Component | Split by |
|---:|---|---|
| 9,297,936 | `lib/arm64-v8a` (libflutter 11.6 MB + libapp 7.7 MB + libsqlite3 1.7 MB uncompressed) | ABI |
| 1,874,956 | `dex` | — |
| 1,158,001 | `assets/…/images` — 118 files | **nothing** |
| 608,393 | `res` | density |
| 593,592 | `assets/lottie` — **unreferenced, see below** | **nothing** |
| 185,406 | `root` | — |
| 62,101 | `resources.pb` | — |
| 34,279 | `assets/{content,config,fonts}` | **nothing** |

`flutter_assets` is the one component Play **cannot** split — every user downloads
all of it on every device. That makes asset discipline the highest-leverage size
lever in this project, ahead of anything in Gradle.

### Rules that keep it small

1. **Build-time inputs never live under `assets/`.** `pubspec.yaml` declares whole
   directories, so a design source dropped in `assets/images/` ships to every user.
   Launcher-icon artwork lives in `tool/branding/`. This one mistake was costing
   2.3 MB per install.
2. **Ship artwork at display resolution, not source resolution.** See the format rule
   in [14-flutter-package-map.md](14-flutter-package-map.md) §9 — WebP for
   accessor-only art, quantised PNG where paths appear in config JSON.
3. **Never pass `--no-tree-shake-icons`.** Verify after every release build:
   ```bash
   unzip -l build/app/outputs/bundle/release/app-release.aab | grep MaterialIcons
   # expect ~15,984 B. 1,645,184 B means tree-shaking was skipped.
   ```
4. **A dependency with zero imports still costs bytes.** Removing six unimported
   packages cut `libapp.so` by 1,638,400 B on its own.

### Known slack, deliberately left in

| Item | Cost | Why it is still here |
|---|---|---|
| `assets/lottie/` — 25 JSON files | 4.86 MB install / 593,592 B download | Nothing renders a Lottie file. Kept pending a decision on whether animated art returns. |
| `drift` + `drift_dev` + `sqlite3_flutter_libs` | `libsqlite3.so`, 1,716,840 B **per ABI** | Zero imports; kept as the scaffold for a future relational store. All persistence runs on Hive today. |
| `flutter_local_notifications`, `app_settings` | registered Android plugins + ~157 KB dex of `j$.time` desugaring | Zero Dart imports; notifications are posted natively. |

Together these are ~2.3 MB of download and ~7 MB of install size. Reclaim them when
the corresponding scaffolds are ruled out — see
[14-flutter-package-map.md](14-flutter-package-map.md) §7.

---

## 3. Permissions Declaration — Accessibility API

Play requires this for any app using `AccessibilityService` for non-accessibility
purposes. Digital-wellbeing / self-control is an accepted use, but it must be declared
and disclosed.

**What the app does with it:**

> Detoxo is a digital-wellbeing app that helps users stop compulsive short-form-video
> scrolling. It uses AccessibilityService for one purpose: to recognise, on-device and in
> real time, when a short-form video feed (Instagram Reels, YouTube Shorts, and similar
> infinite feeds) is on screen inside an app the user has explicitly added to their own
> blocklist — and then to perform a Back action so the feed closes.
>
> The service inspects the foreground window's node tree to match known feed surfaces.
> That evaluation happens entirely on the device, in the moment, and the result is
> discarded immediately. Detoxo does not record, store or transmit screen content,
> keystrokes, messages, URLs or the identity of any video. No other API can observe
> another app's on-screen state on Android, which is why no alternative implementation
> exists.
>
> The same signal drives the app's on-device reel counter, which shows the user how many
> short videos they have watched.

**Prominent disclosure (in-app, shown before the grant):** implemented in
`lib/features/permissions/presentation/permission_actions.dart` — an `AppDialog` titled
*"How Detoxo uses Accessibility"* with **Continue** / **Not now**, shown before the system
Accessibility screen opens. Its wording mirrors `accessibility_service_description` in
`android/app/src/main/res/values/strings.xml`; **keep the two in sync**, since review
compares the in-app disclosure with the service description.

Take a screenshot of that dialog for the Console — reviewers ask where the disclosure is.

---

## 4. Data safety form

Source of truth: [19-firebase-telemetry.md](19-firebase-telemetry.md).

| Question | Answer |
|---|---|
| Does the app collect or share user data? | **Yes** — diagnostics only |
| Data types | **App activity** (in-app actions, screen views), **App info & performance** (crash logs, diagnostics) |
| Personal info / financial / messages / photos / contacts / location / files | **None** |
| Advertising ID | **Not collected** — the permission is stripped via `tools:node="remove"` (§1) |
| Is data encrypted in transit? | **Yes** (Firebase HTTPS) |
| Can users request deletion? | No account exists; data is keyed to a random on-device install ID. **Settings → Reset app data** clears local state |
| Is collection optional? | **No** — currently unconditional. A consent/opt-out toggle is a known gap (see below) |
| Data shared with third parties? | **No** (Firebase is a processor, not a recipient) |

**What is explicitly never sent** (enforced in code): PIN secrets, the specific site or
URL blocked, the specific video watched, the installed-app list, message content, and
the **protected-apps list** (the user's banking/UPI/password apps — it never leaves the
device, and no analytics or log line ever names a protected package; see
[24-protected-apps.md](24-protected-apps.md) §6). `web_blocked` deliberately drops the
host.

**Known gap — telemetry has no opt-out.** Collection is forced on in
`lib/core/services/firebase/firebase_services.dart`. `docs/info_docs/03` describes a
toggle as *planned*, which is honest, but GDPR/DSA exposure for EU users is real. Build
the toggle before a broad EU rollout.

**Verify after every Firebase bump:**

```bash
flutter build appbundle --release
grep -o 'uses-permission android:name="[^"]*"' \
  build/app/intermediates/packaged_manifests/release/processReleaseManifestForPackage/AndroidManifest.xml \
  | sort
```

`AD_ID` and `ACCESS_ADSERVICES_*` must be absent. A new `play-services-measurement`
artifact can reintroduce them under a name the current `tools:node="remove"` list does
not cover.

Privacy policy URL: `AppConstants.privacyPolicyUrl` → `https://detoxo.web.app/#privacy`.
That page lives outside this repo; make sure it actually describes the Firebase collection
above before submitting, or the form and the policy will disagree.

---

## 5. Other declarations

**No foreground service — nothing to declare.** `DetoxoAccessibilityService` is *not* an
FGS. The system binds accessibility services at foreground-service priority already, so
`startForeground()` added no resilience while `FOREGROUND_SERVICE_SPECIAL_USE` would have
required a Console special-use declaration and manual review. The app declares no
`FOREGROUND_SERVICE*` permission and no `android:foregroundServiceType`; the user still
sees the persistent low-priority "Detoxo is active" notification, now posted with
`NotificationManager.notify()`.

`FOREGROUND_SERVICE` does still appear in the **merged** manifest, pulled in transitively
by `home_widget` → `androidx.glance` → `androidx.work`. It is a normal install-time
permission with no Console declaration attached, and stripping a library's permission with
`tools:node="remove"` would make any future WorkManager foreground work throw
`SecurityException` — so it stays. If a reviewer asks, the answer is "transitive from
AndroidX WorkManager; the app starts no foreground service."

**Battery optimisation.** Detoxo does **not** declare
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. The "Unrestricted battery" step opens
`ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` (the system list) rather than the direct
one-tap exemption dialog, which Play policy reserves for apps whose core function fails
without the exemption — not the case here, since the engine is a system-bound
accessibility service.

**Device admin (uninstall protection).** Requests only `force-lock` and `watch-login` —
no wipe, no camera control, no password policy. Off by default, opt-in, and reversible
from Detoxo's own settings or Android's Security settings. Disclose it as a user-initiated
self-control feature that prevents impulsive uninstall and enables the optional
lock-screen block action.

**`SYSTEM_ALERT_WINDOW`.** Used to draw Detoxo's own block screen and reel-counter
bubble over other apps. It never reads or interacts with other apps' content. (The PIN
prompt is an ordinary in-app screen — it does not use this permission.)

**`PACKAGE_USAGE_STATS`.** Powers user-configured daily app usage limits; read on-device,
never uploaded. Granted by the user on Android's own Usage-access screen.

---

## 6. Restricted settings / ECM — expected, not a bug

Android 13+ *Restricted Settings* and Android 15+ *Enhanced Confirmation Mode* block the
Accessibility, overlay and device-admin toggles for apps whose installer is not trusted.
**Play Store installs are exempt**, so this never affects users who install from the
store — including internal-testing testers.

It **does** affect anyone testing a sideloaded APK. The recovery is
**Settings → Apps → Detoxo → ⋮ → Allow restricted settings** (per app, not per
permission). Detoxo detects the situation and offers a **Fix this** walkthrough — see
[13-onboarding-permissions.md](13-onboarding-permissions.md) §3.5.

For local testing you can instead run:

```bash
adb shell appops set com.errorxperts.detoxo ACCESS_RESTRICTED_SETTINGS allow
```

There is no programmatic way to *detect* the gate: the backing appop is `@hide`,
read-restricted, and defaults to `MODE_DEFAULT` under ECM, and
`android.app.ecm.EnhancedConfirmationManager` is not in the public SDK. Detection is
therefore behavioural (attempt count + install source), which is why it is deliberately
conservative.

---

## 7. Pre-submission checklist

- [ ] `bash tool/dev.sh precommit` green (format, analyze, test, boundaries)
- [ ] versionCode bumped in `pubspec.yaml`; `AppConstants.appVersion` matches the build-name
- [ ] `bash tool/dev.sh release` produces a **release-signed** `.aab` (no debug-signing warning)
- [ ] Merged-manifest permission list reviewed (§4 command) — no `AD_ID`, no `QUERY_ALL_PACKAGES`
- [ ] `mapping.txt` uploaded to the Console; `build/symbols/` uploaded via `flutter symbols upload`
- [ ] Accessibility Permissions Declaration submitted (§3) + disclosure screenshot attached
- [ ] Data safety form completed (§4); privacy-policy page matches it
- [ ] Store listing from [../info_docs/01-product-overview.md](../info_docs/01-product-overview.md) §"App-store listing copy"
- [ ] Screenshots + feature graphic prepared (**not in this repo** — still to be produced)
- [ ] Internal-testing install verified: no restricted-settings gate, blocking works end to end

### Known blockers still open

| Item | Impact |
|---|---|
| No telemetry consent/opt-out | GDPR/DSA exposure for EU users |
| Privacy-policy page content unverified (lives outside this repo) | Data-safety form may contradict the published policy |
| No store screenshots / feature graphic in repo | Listing cannot be completed |
| App blocker + daily limit are UI-only (not enforced natively) | Do not claim them as working features in the listing |
| 12 grandfathered feature-boundary violations (`tool/boundaries_baseline.txt`) | Engineering debt, not a Play blocker |
