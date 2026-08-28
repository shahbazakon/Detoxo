---
name: docs-sync
description: Keep the Detoxo documentation in sync with the code. Invoke after changing any feature under lib/features/** or its native counterpart under android/app/src/main/kotlin/com/errorxperts/detoxo/** (or config/assets/pubspec) to update the matching engineering doc in docs/code_docs/ and, for user-facing changes, the relevant docs/info_docs/ section. Triggers: "update the docs", "docs sync", "keep docs in sync", "which doc covers this feature", after implementing/altering a feature or module.
---

# docs-sync — keep Detoxo docs truthful

When a feature or module changes, the doc that describes it must change with it. This skill
tells you **which doc(s)** to update and **how** to keep them accurate.

## When to run
Run this after you add, remove, or meaningfully change:
- a feature under `lib/features/**`, or
- its native code under `android/app/src/main/kotlin/com/errorxperts/detoxo/**`, or
- `pubspec.yaml`, `assets/config/*.json`, `assets/content/*.json`, or the manifest / `res/xml`.

Skip it for pure test/formatting changes with no behavioral or structural effect.

## Documentation layout
- `docs/code_docs/` — engineering docs (`00-index.md`, `01`–`24`). Authored **from source**;
  each ends with a **`## Source files`** section listing the real files it documents.
- `docs/info_docs/` — end-user / marketing docs (`00-index.md`, `01`–`04`): product overview,
  feature walkthroughs, permissions explained, FAQs.

## Mapping — what to update when you touch…

| Change in… | Update code_doc(s) |
|---|---|
| `lib/features/blocking/shared/**` or native `engine/{ConfigStore,DetectionConfig}.kt` | 02, 03, 10 |
| native `accessibility/DetoxoAccessibilityService.kt`, `engine/**` | 03, 04 |
| `lib/features/blocking/{engine,blocklist}/**` | 01, 04, 18 |
| `lib/features/blocking/plans/**`, `assets/content/**` | 05 |
| `lib/features/limits/{app_blocker,web_blocker}/**`, native `engine/WebBlockEngine.kt`, `tool/web_blocker/**` (18+ list source + compiler → `adult_domains.txt.gz`) | 06 |
| `lib/features/limits/daily_limit/**` | 07 |
| `lib/features/access_protection/**` | 08 |
| `lib/core/storage/**`, native `engine/{ConfigStore,ContentCounterStore}.kt` | 09 |
| `lib/features/blocking/shared/data/**`, `lib/core/network/**` | 10 |
| `lib/features/monetization/premium/**` | 11 |
| `lib/features/analytics/**`, native FGS notification / `receivers/BootReceiver.kt` / `admin/DetoxoDeviceAdminReceiver.kt` | 12 |
| `lib/features/{onboarding,permissions}/**`, `lib/app/splash_screen.dart` | 13 |
| `lib/features/dashboard/**` (home shell + dashboard sections), `lib/core/design_system/foundations/**` (glass primitives) | 01 (+ **user-facing** → `info_docs/02` §1) |
| `pubspec.yaml` | 14 |
| `lib/app/unsupported_screen.dart`, `lib/core/platform/**` | 15 |
| release status / what-works-vs-swap-in changes | 16 |
| `lib/features/content_counter/**`, native `engine/ContentCounter*.kt`, `overlay/**`, `widget/**` | 17 |
| `lib/features/additional_feature/appearance/**` (Appearance screen: theme + background + reel-counter hub) | 17 (theme/background source is `blocking/shared` `SettingsCubit`; **user-facing** → `info_docs/02` §8–§9) |
| `lib/core/constants/channel_constants.dart`, native `channels/**` | 18 |
| `lib/features/protected_apps/**`, the service's privacy guard (`isProtected` sites in `DetoxoAccessibilityService.kt`) | 24 (+ 03, 04, 09, 18; **user-facing** → `info_docs/02` §13 + `04`) |
| `lib/core/services/firebase/**`, `lib/firebase_options.dart`, Firebase Gradle plugins (`android/settings.gradle.kts`, `android/app/build.gradle.kts`) | 19 (+ 12, 14, 16; **privacy** → `info_docs/03` + `04`) |
| `lib/features/help/**`, `lib/features/additional_feature/showcase_view/**` | 20 (+ user-facing → `info_docs/02` + `04`) |
| `lib/features/additional_feature/app_upgrader/**`, `lib/core/design_system/components/{dialog,overlays}.dart` (blocking-dialog params), the update entry points in `settings_screen.dart` (`_VersionBanner`) / `daily_limit_screen.dart` (`InfoBanner`) | 21 (+ user-facing → `info_docs/02` + `04`) |
| **any user-facing behavior change** | the matching `info_docs/02-feature-walkthroughs.md` section **and** `info_docs/04-faqs.md` |

New feature area with no mapping? Add a row here, and either extend the closest doc or add a
new `code_docs/NN-*.md` and register it in `docs/code_docs/00-index.md`.

## How to update a doc
1. Read the changed source **and** the doc's existing `## Source files` list.
2. Correct the affected sections so every statement matches the code. Verify these
   load-bearing facts stay right when they appear:
   channels `com.errorxperts.detoxo/commands` + `/events`; timings `throttle 150 / debounce
   1200 / back 1100 ms`, `maxNodeTraversal 12000`; notification `detoxo_protection_channel`
   id `1125`; service runs in the **main process**; content counter uses `detoxo_engine_prefs`
   and runs **independently of blocking**; premium is a dev-unlock; iOS is unsupported.
3. Update the doc's `## Source files` list if the set of files changed.
4. If the change is user-visible, update the matching walkthrough section and add/adjust an FAQ.
5. Check cross-links (no link should point at a file that doesn't exist).

## Naming invariants (do not break)
- Brand is **Detoxo**; package/appId **`com.errorxperts.detoxo`**; asset/vendor namespace
  **errorxperts**. These are the only app/vendor names in the repo — never reintroduce a prior
  app's or prior vendor's name when copying blueprint text, and never a `:as_process` suffix
  (this build is single-process).
- The plan token **`curious` / `"CURIOUS"`** is real (native `PLAN_CONSCIOUS = "CURIOUS"`) and
  must stay verbatim in code/wire contexts. Its **user-facing label is "Conscious"** — use
  "Conscious" in prose and `info_docs`, `curious`/`CURIOUS` when quoting code/enums/wire.
