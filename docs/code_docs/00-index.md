# Detoxo — Engineering Documentation

The technical reference for **Detoxo**, written **from the shipped source**. Detoxo is an
Android-first short-form-content blocker + on-device reel counter:
**Flutter (flutter_bloc Cubit + get_it + go_router, feature-first Clean Architecture)** driving a
native **Kotlin AccessibilityService** engine (`com.errorxperts.detoxo`). The hot detection/block
path is native; Dart owns config, settings and UI, bridged by **one** MethodChannel
`com.errorxperts.detoxo/commands` + **one** EventChannel `com.errorxperts.detoxo/events`.

> End-user & marketing docs live in [`../info_docs/`](../info_docs/00-index.md).
> Planned, not-yet-built capability lives in [`../plan_docs/`](../plan_docs/00-index.md) —
> **this set only ever describes shipped code.**

## Suggested reading order
1. **Orient** → [01 Overview & Architecture](01-overview-architecture.md)
2. **The data** → [02 Detection Config Schema](02-detection-config-schema.md)
3. **The engine** → [03 Detection & Block Engine](03-detection-engine.md) + [04 Native Android Layer](04-native-android-layer.md)
4. **The contract** → [18 Platform Channel Contracts](18-platform-channel-contracts.md)
5. **Features** → 05–13, [17 Content Counter](17-content-counter.md)
6. **Telemetry** → [19 Firebase Telemetry](19-firebase-telemetry.md) (the one off-device data path)
7. **Status** → [16 Status & Roadmap](16-implementation-roadmap.md)

## Document map
| # | Doc | Covers |
|---|-----|--------|
| 00 | this file | Index + glossary |
| 01 | [Overview & Architecture](01-overview-architecture.md) | Feature inventory, Clean Architecture, Cubit/get_it/go_router, the bootstrap + `AppGate` redirect, native boundary, directory map |
| 02 | [Detection Config Schema](02-detection-config-schema.md) | `platforms_config.json` / `initial_config.json` as consumed; freezed models; native parse |
| 03 | [Detection & Block Engine](03-detection-engine.md) | The native event loop, 3-stage view-id detection, timings, block modes, Conscious/Pause gating |
| 04 | [Native Android Layer](04-native-android-layer.md) | Service (main process, FGS), receivers, device admin, overlay, manifest, `res/xml` |
| 05 | [Plans, Pause & Conscious](05-plans-pause-conscious.md) | Block-All / Conscious / One-Reel / Pause, the Conscious time-bank, countdown & content engine |
| 06 | [App Blocker & Web Blocklist](06-app-and-web-blocker.md) | Full-app blocking + website blocklist (`WebBlockEngine`) |
| 07 | [Daily Limit & Scheduler](07-daily-limit-scheduler.md) | Daily time quota + reset |
| 08 | [PIN Lock & Biometrics](08-pin-lock-recovery.md) | PIN gate, lockout ladder, biometric/device-credential unlock, Smart Auto Lock + Recents privacy; why there is no recovery channel |
| 09 | [Persistence & Data Model](09-persistence-data-model.md) | `local_store` + `detoxo_engine_prefs` + secure storage + widget keys |
| 10 | [Config Sync (offline-first)](10-networking-config-sync.md) | Bundled config load; remote as swap-in |
| 11 | [Monetization](11-monetization.md) | Premium entitlement model + dev-unlock; ads/billing SDKs removed pending real monetization |
| 12 | [Analytics, Notifications & Resilience](12-analytics-notifications-resilience.md) | Native block counts (the Activity tab's Blocked tiles, yesterday reference and per-app rows); FGS notification; boot; device-admin |
| 13 | [Onboarding & Permission Funnel](13-onboarding-permissions.md) | Persisted first-run step machine + starter rule + permission funnel + the router gate |
| 14 | [Flutter Package Map](14-flutter-package-map.md) | Real `pubspec.yaml` deps → purpose |
| 15 | [iOS / Cross-Platform Reality](15-ios-cross-platform.md) | Why iOS is unsupported; capability gating |
| 16 | [Status & Roadmap](16-implementation-roadmap.md) | What works vs swap-in follow-ups; testing; compliance |
| 17 | [Content Counter](17-content-counter.md) | The decoupled reel/short counter: native pass, bubble, home widget |
| 18 | [Platform Channel Contracts](18-platform-channel-contracts.md) | Every command method + event payload |
| 19 | [Firebase Telemetry](19-firebase-telemetry.md) | Analytics / Crashlytics / Performance service layer — the one off-device data path |
| 20 | [Help & Support](20-help-support.md) | In-app help hub: report an issue, FAQ, feature tutorials (scoped tours), share an idea |
| 21 | [App Upgrader](21-app-upgrader.md) | In-app "update available" prompt (`upgrader` engine + custom glass dialog, force-update, auto + manual check) |
| 22 | [Play Store Release & Policy](22-play-release.md) | Signed `.aab` build, Accessibility/FGS/device-admin declarations, data-safety answers, restricted-settings notes |
| 23 | [Testing Runbook & IDE Run Configs](23-testing-runbook.md) | How to run every layer — terminal, Android Studio, VS Code; artifacts; troubleshooting |
| 24 | [Protected Apps (Privacy Exclusion)](24-protected-apps.md) | User-managed sensitive apps (banking/UPI/password managers) Detoxo ignores entirely: native privacy guard, catalog seeding, `pushProtectedApps` |
| 25 | [Block Screen](25-block-screen.md) | The intervention wall: native full-screen overlay raised at a block (window, gesture defence, four trigger sites, hide rules, renderer, style + on/off switch, six commands + `blockScreenAction`) |
| 26 | [Category Catalog & Usage Signal](26-catalog-and-usage-signal.md) | The app/website taxonomy (`Catalog.bundled`) and the pull-only `UsageStatsManager` layer (`queryAppUsage` / `queryUsageEvents`, the two throwing arms) |
| 27 | [Rules Engine](27-rules-engine.md) | Schedules, daily time limits and open limits: Dart resolves rules to a flat snapshot with absolute windows, native `RuleEngine` enforces it (`pushRules` / `ruleBoundary`); the Daily Limit is finally enforced through its native reel-time meter; the dashboard Rules card, list + editor |
| 28 | [Insights](28-insights.md) | Real screen time from `UsageStatsManager`: the pure `computeDailyStats` fold (distraction time, pickups, context switches, top apps), the 90-day `usage_daily` rollup, and the Activity tab that hosts it (reel counter, block tiles, override history, then insights) |
| 29 | [Notification Suppression](29-notification-suppression.md) | Cancels notifications from apps blocked right now (`NotificationListenerService` + the Android-free `SuppressionDecision`), so a locked app can't advertise itself back; the set is derived per notification, never pushed or stored |
| 30 | [Soft Nudge](30-soft-nudge.md) | The advisory middle setting between blocked and not: the Android-free `NudgeTracker` dwell machine and its own bottom-anchored, touch-passthrough card (`pushNudgeConfig` / `nudgeShown`). Never blocks, never presses BACK |
| 31 | [Locked Rules & Per-Target Unblock](31-locked-rules-and-unblock.md) | "Unblock Instagram for 15 minutes, leave everything else protected": the Android-free `UnblockRegistry` (`pushTemporaryUnblocks`, monotonic expiry), the wall's Unblock button, the web per-site pause folded into it — and the other half, rules that have no off switch and a rationed override that lifts one by splitting its own windows |

## Glossary
| Term | Meaning |
|---|---|
| **Detection** | Reading the foreground app's accessibility node tree to decide "this is a reel/short". |
| **Block mode** | What happens on detection: `PRESS_BACK`, `KILL_APP`, `LOCK_SCREEN`, `NONE`. |
| **Plan** | The active blocking strategy: Block-All, **Conscious** (`curious`/`"CURIOUS"`), One-Reel, Paused. |
| **Conscious** | The UI label for the `curious`/`"CURIOUS"` plan — an earn-as-you-abstain time-bank; reels play while the bank has allowance, then Back is pressed. |
| **Content counter** | A separate, side-effect-free counting pass (independent of blocking) that tallies reels/shorts and drives the bubble + home-screen widget. |
| **Commands / Events channel** | `com.errorxperts.detoxo/commands` (Dart→native) and `/events` (native→Dart, multiplexed by `type`). |
| **`detoxo_engine_prefs`** | The native `SharedPreferences` file the engine persists settings/plan/stats/counts to (readable even when the UI process is gone). |

> Every doc ends with a **`## Source files`** section — the anchor the `/docs-sync` skill uses
> to keep it truthful when the code changes.
