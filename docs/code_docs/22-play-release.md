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
> scrolling. It uses AccessibilityService for two closely related purposes, both on-device
> and in real time. The first is to recognise when a short-form video feed (Instagram Reels,
> YouTube Shorts, and similar infinite feeds) is on screen inside an app the user has
> explicitly added to their own blocklist — and then to close the feed with a Back action and,
> when the user has chosen the "Block screen" mode or a limit or schedule they set has run out,
> show Detoxo's own full-screen block screen, drawn with the user-granted "Display over other
> apps" permission, which names what was blocked and offers "Go home", "Open Detoxo" and
> "Back to the app". The second is to measure how long the user has been in an app they asked
> to be reminded about, and show a small dismissible card saying so. That second use closes
> nothing and blocks nothing; it is off by default and reads no screen content at all — only
> which app is in the foreground.
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

**What is explicitly never sent** (enforced in code): PIN secrets, **anything at all about a
notification** (the listener reads only a notification's package name, key, user and category —
never its title, text, sender or extras — and stores, logs and transmits none of it; see
[29](29-notification-suppression.md) §5), the specific site or
URL blocked, the specific video watched, the installed-app list, message content, the
**per-app screen-time figures** behind the Insights screen (`usage_daily` is local Hive
only — the telemetry layer has no insights event, [28](28-insights.md) §8), and
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

`FOREGROUND_SERVICE` no longer arrives transitively (the `home_widget` →
`androidx.glance` → `androidx.work` chain went with that package on 2026-08-29).
**Drift to resolve before the next submission:** `android/app/src/main/AndroidManifest.xml`
lines 7–8 still declare `FOREGROUND_SERVICE` **and** `FOREGROUND_SERVICE_SPECIAL_USE`
directly, and the service calls `startAsForeground()` — which contradicts the paragraph
above. Either drop the two `uses-permission` lines and the FGS call, or keep them and file
the special-use declaration in the Console; this doc describes the intended state, not
the manifest as it stands.

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

**`SYSTEM_ALERT_WINDOW`.** Used to draw Detoxo's own three windows over other apps:
the block screen, the reel-counter bubble, and the soft-nudge card
([30](30-soft-nudge.md)) — a small bottom-anchored card that states how long the user
has been in an app, auto-dismisses after ~6 s, passes every touch outside its own
bounds straight through to the app underneath, and blocks nothing. It never reads or interacts with other apps' content. (The PIN
prompt is an ordinary in-app screen — it does not use this permission.) The block screen
([25](25-block-screen.md)) is raised by the accessibility service at the moment of a block. It
is always dismissible from an on-screen action ("Go home" and "Open Detoxo" are never delayed;
only the way back into the blocked app waits a few user-configurable seconds), is under the
user's control (for reel blocks it appears only in the "Block screen" mode the user picks under
Settings → When a reel is detected, for app and website blocks it can be switched off under
Appearance → Block screen, and for a daily limit, schedule or Conscious bank the user set it is
removed by removing that rule), never imitates system UI, never covers a system
dialog or an app that comes to the foreground other than the one the block came from, the
launcher, or the app that block was opened from (where it waits for the user's own exit), captures
no input meant for other apps, and is removed on screen-off, on Pause, when protection is
switched off, and when the overlay grant is revoked — in which case blocking degrades to the
existing toast + Back. The in-app `accessibility_service_description`
("…and block it") already covers the wall, so the disclosure dialog is unchanged.

**`BIND_NOTIFICATION_LISTENER_SERVICE` (notification suppression).** The highest-scrutiny
declaration in the app, because it sits alongside an AccessibilityService and device-admin.
Declare it as a user-initiated self-control feature: while the user's **Notification silence**
toggle is on, notifications from apps *the user has locked or scheduled in Detoxo* are dismissed
so a blocked app cannot pull them back.

What to state, all of it enforced in code ([29](29-notification-suppression.md) §5):

- **Notification metadata only.** `onNotificationPosted` reads `packageName`, `key`, `user` and
  `notification.category` — the last being a fixed Android constant naming the *kind* of
  notification (message, call, alarm…), chosen by the sending app from a closed set. It never
  touches `.extras`, so no title, text, sender or image is ever accessed. Grep-checkable, and
  part of the release checklist below.
- **Messages and calls are never silenced**, even from a blocked app: the feature blocks the
  feed, not the person (EVO-038).
- **Nothing is stored, logged or transmitted.** No package name reaches Logcat; there is no
  analytics event; a cancelled notification is never read, modified or re-posted.
- **Off by default and opt-in**, with a **prominent in-app disclosure shown before** the system
  grant screen, stating plainly that Android grants access to every notification on the device
  and what Detoxo does with it. Reversible from Detoxo's own settings at any time.
- **Unbound while off.** Turning the toggle off calls `requestUnbind()`, so Detoxo stops
  receiving notifications entirely rather than receiving and discarding them.
- **Protected apps are exempt**, always — banking, UPI and password managers are refused above
  every other check, even when also locked or scheduled ([24](24-protected-apps.md)).

No new `<uses-permission>` is declared: the `BIND_` guard sits on the `<service>` tag and is
held by the system. Like accessibility, overlay and device admin, the toggle is subject to
restricted settings / ECM on sideloaded installs (§6).

**`PACKAGE_USAGE_STATS`.** Powers user-configured daily app usage limits **and the
Insights screen** (the user's own screen time, pickups and top apps —
[28](28-insights.md)); read on-device, stored on-device, **never uploaded**. Granted by
the user on Android's own Usage-access screen, and optional: without it Insights shows a
grant card rather than any number.

> **Re-check before the next release.** Insights broadened what is *held* on device (a
> 90-day per-app usage history under `usage_daily`), though not what is *sent* — the
> answers in §4 are unchanged because nothing new leaves the device. The in-app
> disclosure's promise that "your counts and settings stay on your device" now covers
> this data too, and still holds.

---

## 6. Restricted settings / ECM — expected, not a bug

Android 13+ *Restricted Settings* and Android 15+ *Enhanced Confirmation Mode* block the
Accessibility, overlay, device-admin and notification-access toggles for apps whose installer is
not trusted.
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
- [ ] Notification-access declaration submitted (§5) + its disclosure screenshot attached
- [ ] `grep -rn "\.extras" android/` matches only the KDoc forbidding it — no notification content is ever read ([29](29-notification-suppression.md) §5)
- [ ] Notification-access disclosure copy still matches what the listener reads (`permission_actions.dart` `_disclosureFor`) — it names the category read, not just the package
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
| ~~Daily limit is UI-only~~ — **resolved by M3** ([27](27-rules-engine.md)): the rules snapshot carries `daily_reel_limit`, metered natively against `ContentCounter.timeTodayMs()` | It may now be listed, along with the natively enforced app blocker (HOME-bounce via `pushAppBlocklist`) |
| ~~7 grandfathered feature-boundary violations~~ — **resolved**: `tool/boundaries_baseline.txt` has been empty since M6, and on 2026-09-06 the gate's own extraction regex was repaired so a feature's top-level `presentation/` import is no longer skipped | — |
