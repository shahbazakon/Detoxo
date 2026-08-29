# Contracts & storage — the consolidated delta

- Status: **living contract — reconciled against shipped code on 2026-09-06.** Eight of the nine
  milestones have shipped (M0, M1, M3, M4, M5, M6, M7, M8); **M2 alone remains forward spec.**
  Every shipped section below carries a `Shipped` note recording what actually landed.
- Covers: M0 – M8
- Companion to the shipped contract, [`code_docs/18-platform-channel-contracts.md`](../code_docs/18-platform-channel-contracts.md), and the shipped storage model, [`code_docs/09-persistence-data-model.md`](../code_docs/09-persistence-data-model.md)

The single source of truth for every wire and storage change in this plan, so no milestone invents
its own shape. If a milestone doc and this doc disagree, **this doc wins** — fix the milestone.

> **How to read the numbers.** Every count in this document is a measurement of the code as it
> stands, not a projection. Each one has a one-line command behind it in
> [Validation](#validation-for-the-contract-itself); if a count and the command disagree, the
> command is right and this document is stale. That failure mode is exactly what produced the
> 2026-09-04 reconciliation — the file spent seven shipped milestones asserting its own pre-M0
> snapshot as "today".

---

## The one channel pair

```
MethodChannel   com.errorxperts.detoxo/commands      Dart -> native
EventChannel    com.errorxperts.detoxo/events        native -> Dart  (multiplexed by `type`)
```

The suggestion set proposes **seven** channel namespaces across its documents. All seven collapse
into these two:

| Source-set namespace | Becomes |
|---|---|
| device-signal control + events | `queryAppUsage`, `queryUsageEvents` (M0.2) |
| usage-stats channel | same |
| block-screen channel | `showBlockScreen`, `hideBlockScreen`, `isBlockScreenShowing`, `goHome` (M1) |
| enforcement-service channel | nothing — the AccessibilityService already *is* the FGS |
| permissions channel | nothing — the existing 6-permission funnel already covers it |
| notification-suppression channel | nothing — M5 shipped one flag on `pushSettings` (see below) |
| activity + activity-events + light sensor channels | `pushNudgeConfig` (M7); the sensor channels are dropped entirely |

**Adding a third channel is a defect, not a design choice.** Verified: a grep over `docs/plan_docs/`
yields only `/commands` and `/events`, and there is no other `MethodChannel(` / `EventChannel(`
construction anywhere in `lib/` or `android/` (the pair is registered once, in `MainActivity.kt`).

---

## Command methods

**Today: 50.** `ChannelMethods` declares 50 constants; `CommandHandler.kt`'s `when` handles 50
literals across 49 branches (`queryAppUsage` and `queryUsageEvents` share one). The set difference
is empty in **both** directions — no Dart constant native ignores, no native branch Dart never
sends. Every constant's Dart name equals its wire value.

The 50th is `unsupportedBrowsers` (EVO-047, 2026-09-04): a read-only query returning the installed
browsers outside native `KNOWN_BROWSERS`, so the Website blocker can name what it cannot enforce in.

M2 adds none. **M8 added two, so the surface is now 52** — see its section below for why the
second (`takePendingUnblock`) replaced the event this file once budgeted for.

Every arm follows the fail-safe contract the existing ones hold — a missing or malformed argument
is a logged no-op, never a throw — with **two deliberate exceptions**, marked below.

### M0.2 — usage signal · **Shipped** ([`code_docs/26`](../code_docs/26-catalog-and-usage-signal.md))

| Method | Args | Returns |
|---|---|---|
| `queryAppUsage` | `{startMillis: Long, endMillis: Long}` | `List<{package: String, foregroundMillis: Long}>`, `foregroundMillis > 0` only |
| `queryUsageEvents` | `{startMillis: Long, endMillis: Long}` | `List<{package: String, type: Int, timestampMillis: Long}>`, `type ∈ {1, 18}` only |

> **The two exceptions.** Both **throw**: `PlatformException("BAD_ARGS")` on invalid bounds and
> `PlatformException("USAGE_ACCESS_DENIED")` when the grant is missing. Returning `[]` would be
> indistinguishable from a genuinely quiet day and would let a screen print a confident wrong
> number. Absence of permission is not absence of usage — see EVO-014.
>
> **Shipped detail:** `BAD_ARGS` is checked **first**, so malformed bounds win even without the
> grant. These two are the only users of `EngineChannel.invokeOrThrow`; every other arm goes
> through `_invoke`, which swallows `PlatformException` into `null`.

Both run on `CommandHandler`'s existing `ioExecutor` and post back on the main looper, matching
`installedPackages` / `installedApps`.

### M1 — block screen · **Shipped** ([`code_docs/25`](../code_docs/25-block-screen.md))

| Method | Args | Returns |
|---|---|---|
| `showBlockScreen` | the payload below | `true`; `false` when the wall is switched off, overlay permission is missing, or the payload is unusable |
| `hideBlockScreen` | — | `true` |
| `isBlockScreenShowing` | — | `Boolean` |
| `goHome` | — | `true` |
| `setBlockScreenStyle` | `{style: Map}` — `enabled`, `theme`, `background`, `showCount`, `showOpens`, `accentByUsage`, `backDelaySec` | `true` |
| `blockScreenStyle` | — | the persisted style `Map` (`{}` when unset) so the editor hydrates from native, the single source of truth (no `StoreKeys` entry) |

> **Shipped delta (M1).** Six commands, not five — `blockScreenStyle` was added for hydration. The
> style map gained `showOpens` (EVO-027) and `backDelaySec` (EVO-025) beyond the five originally
> specified. The payload gained `appLabel`, `allowance`, `packageName`, `opensToday` and
> `unlocksAtMs`; the event gained `preview: Bool`; the wall's `enabled` switch lives inside
> `block_screen_style`.

```jsonc
// showBlockScreen payload — 15 fields as shipped. Only the first two are required;
// an absent one yields a null payload and the call returns false.
{
  "referenceType": "REEL" | "APP" | "WEBSITE",   // required
  "blockReason":   "PLAN" | "APP_BLOCK" | "WEB_RULE" | "ADULT" | "DAILY_LIMIT" | "SCHEDULE",  // required
  "referenceId":   "com.instagram.android",  // ""
  "displayName":   "Instagram Reels",        // ""
  "appLabel":      "Instagram",              // ""   renders "Back to Instagram"
  "packageName":   "com.instagram.android",  // ""   EVO-027
  "plan":          "BLOCK_ALL" | "CURIOUS" | "ONE_REEL",  // ""
  "allowance":     1,                        // 1    "One Reel" vs "Unblock N"
  "todayCount":    42,                       // -1 = skip the line
  "allowanceLeft": -1,                       // -1 = not applicable
  "bankMs":        -1,                       // -1 = not applicable
  "opensToday":    7,                        // -1   EVO-027
  "unlocksAtMs":   -1,                       // -1   EVO-028
  "offersOpenApp": true,                     // renders "Open Detoxo"
  "offersUnblock": false                     // renders "Unblock for a while" — M8 handles the tap
}
```

**`.sanitised()` runs on every channel call**, and it is part of the contract, not an
implementation detail: for `blockReason: "ADULT"` it blanks `displayName` **and** `referenceId`
and forces `offersUnblock = false`; for any non-`PLAN` reason it blanks `plan`. The channel arm
also always passes `preview = true` — a Dart-driven `showBlockScreen` can only ever raise the
editor's preview wall, never a real intervention.

`offersUnblock` is the source set's own field. **M1 ships the button and the event; M8 ships the
flow.** Until M8 lands it is `false` everywhere, so M1 was shippable alone. It is `false`
unconditionally for `blockReason: "ADULT"` — an adult-list hit is never named (EVO-018) and must
never be one tap from being lifted.

> `plan` carries **`CURIOUS` verbatim** — it is the wire token. The rendered label is
> **"Conscious"**, mapped inside `BlockScreenRenderer`. A test asserts `"curious"` never reaches a
> user-visible string.

### M3 — rules · **Shipped (lean core)** ([`code_docs/27`](../code_docs/27-rules-engine.md))

| Method | Args | Returns |
|---|---|---|
| `pushRules` | `{json: String, nextBoundaryMs: Long}` | `true`; no-op on null/non-array; skips when unchanged |

`json` is the **resolved snapshot**, not the stored rule. It is deliberately smaller and dumber:
native does two long comparisons and a set lookup, and parses no schedule.

```jsonc
// One entry per rule, windows resolved 7 days ahead. 13 keys as shipped.
[{
  "id":              "uuid",
  "reason":          "SCHEDULE",              // -> blockReason on the wall
  "mode":            "BLOCK",                 // BLOCK | ALL_EXCEPT
  "packages":        ["com.instagram.android"],   // categories already flattened
  "domains":         ["instagram.com"],           // lower-cased natively
  "platformIds":     ["ig_reels"],
  "windows":         [[1756789200000, 1756818000000]],  // ABSOLUTE [fromMs, untilMs] pairs
  "always":          false,
  "reelTimeLimitMs": 0,
  "strict":          false,                   // a Pause cannot lift it (EVO-030)
  "usageLimitMs":    0,
  "openLimitCount":  0,
  "spent":           false                    // flipped natively by the watchdog (EVO-029)
}]
```

`nextBoundaryMs` is the earliest time any window opens or closes. Native stores it and, at the
existing `WatchdogJobService` tick (15 min) and on `WINDOW_STATE_CHANGED`, posts `ruleBoundary`
once it has passed. **No new ticker.**

> **Shipped delta (M3).** The snapshot is **one entry per rule with nested absolute windows**, not
> a flat `activeFromMs`/`activeUntilMs` per entry; `always: true` + `reelTimeLimitMs > 0` is the
> synthetic `daily_reel_limit` entry that enforces the global Daily Limit against native's
> reel-time counter. Four keys beyond the original spec shipped: `strict`, `usageLimitMs`,
> `openLimitCount`, `spent`. `nextBoundaryMs` is **always** written (it moves even when the
> snapshot does not). `ruleBoundary` shipped as specified; **`usageLimitReached` did not** — the
> existing `blocked` event gained a `reason` field instead. Native gained `rules_json` and
> `next_boundary_ms`; Hive gained `rules` (no stored limit state — usage is re-derived on every
> reconcile).

### M4 — insights · **Shipped** ([`code_docs/28`](../code_docs/28-insights.md))

> **Shipped delta (M4).** **No channel delta and no new method.** M4 is a pure consumer of M0.2's
> two arms plus `contentCounterSnapshot`. Its only contract surface is the `usageDaily` Hive
> record (below). Open counting is done by a native `UsageQuery.countOpens` helper, which is
> internal and not a channel method.

### M5 — notification suppression · **Shipped, with the pushed set dropped** ([`code_docs/29`](../code_docs/29-notification-suppression.md))

| Method | Args | Returns |
|---|---|---|
| `pushSettings` | gains one field: `{suppressNotifications: Bool}` | `true` |
| `isNotificationListenerEnabled` | — | `Boolean` |
| `openNotificationListenerSettings` | — | `Boolean` (launch ok) |

> **Shipped delta (M5) — read this before citing an older revision of this file.** This plan
> originally specified a `pushSuppressedApps` method, a `StoreKeys.suppressedApps` record and a
> `suppressed_packages` StringSet. **None of the three was built, and none exists in the codebase.**
>
> The design changed once M3 shipped first: the suppressed set is a *projection* of rules and
> blocklists, so pushing and storing it would have created a second source of truth that could
> disagree with the first — and the plan's own storage rule 3 ("derived data is not stored")
> forbids exactly that. Instead **the set is never computed, pushed or stored**: every notification
> is decided against the engine's live in-memory state. Dart owns one boolean, which rides the
> existing `pushSettings` arm, and the permission grant.
>
> The flag is load-bearing beyond a filter: `suppressNotifications = false` makes the listener
> **unbind**, so Detoxo receives no notifications at all rather than receiving every one on the
> device and discarding it.

### M6 — onboarding & shell · **Shipped** ([`code_docs/13`](../code_docs/13-onboarding-permissions.md) + [`code_docs/01`](../code_docs/01-overview-architecture.md) §3–§4)

> **Shipped delta (M6).** **No channel delta and no native storage delta.** Onboarding drives the
> existing permission commands. Its only contract surface is the `onboardingProgress` Hive record
> — and note that *completion* is not stored there: it lives on `AppSettings.onboarded`. M6 is the
> one shipped milestone with no `code_docs/NN` of its own; it folded into 13 and 01.

### M7 — soft nudge · **Shipped** ([`code_docs/30`](../code_docs/30-soft-nudge.md))

| Method | Args | Returns |
|---|---|---|
| `pushNudgeConfig` | `{enabled: Bool, packages: List<String>, thresholdStepMs: Long, dailyCap: Int}` | `true`; each field independently a no-op when absent |

> **Shipped delta (M7).** The fourth argument is **`dailyCap`, not `idleTimeoutMs`** — the idle
> timeout stayed a native constant because it is not user-facing, while a per-app daily cap was
> needed to stop the card becoming wallpaper. Native therefore mirrors **four** keys, not two
> (below). There is **no `StoreKeys` record**: three scalars ride on `AppSettings`, so the
> `soft_nudge` key this plan once specified was never created. `packages` is the catalog's
> `distracting` behaviour **minus the user's protected apps**, subtracted natively.

### M2 — friction & passes · *forward spec*

> **M2 adds no command and no event.** Stated explicitly because this file is the wire
> source-of-truth and a future executor should not invent one: the grant applies through commands
> that already exist — `pushSettings {pauseUntil}` for Pause and `armReelSession {count}` for
> One Reel / Unblock. Its whole surface is two Hive records.

### M8 — per-target unblock & locked rules · **Shipped** ([`code_docs/31`](../code_docs/31-locked-rules-and-unblock.md))

| Method | Args | Returns |
|---|---|---|
| `pushTemporaryUnblocks` | `{json: String}` — `[{targetType, targetId, endMs}]` | `true`; no-op on null/non-array; skips when unchanged |
| `takePendingUnblock` | — | `String?` — `"TYPE\|id"`, read **and cleared** |

```jsonc
[{ "targetType": "APP",                      // REEL | APP | WEBSITE
   "targetId":   "com.instagram.android",    // platformId | package | host
   "endMs":      1756743300000 }]
```

> **Shipped delta (M8).** **Two** commands, not one. `takePendingUnblock` replaced the
> `temporaryUnblockExpired` event this file once budgeted for: the wall's Unblock tap foregrounds
> Detoxo, and on a cold start the EventChannel sink does not exist when `blockScreenAction` is
> posted — so the target is handed over through a consumable prefs key instead. Net: commands
> 50 → **52**, events **9** (unchanged).
>
> `UnblockRegistry.isUnblocked` is checked at the **four non-strict branches**, not at one place
> above every branch — native only has `pkg` at the privacy guard, and the reel and web ids appear
> ~150 lines later. The strict arm deliberately never reads the registry, which is what guarantees
> a one-tap unblock cannot lift a strict (or locked) rule.
>
> `endMs` is a wall stamp on the wire but a **monotonic** deadline in memory, converted once per
> parse — the signature `isUnblocked(type, id, nowMs)` in the M8 doc predates EVO-048 and would
> have re-opened the clock-rollback bypass it closed.

**Locked rules add no command — and no snapshot key either.** `locked` / `lockScope` stay
Dart-side; a locked rule is emitted as `strict: true` (`Rule.isStrict`), so native learns nothing
new. They are still a change to the **`rules` Hive record**, sparsely.
`lockScope: DISTRACTING` is resolved through M0.1's catalog **at snapshot time** — gated to a
`SCHEDULE` in `BLOCK` mode, because widening a limit would widen its *budget* and widening an
`ALL_EXCEPT` rule would invert it.

**An override is not a grant.** It lifts one RULE, by subtracting its window from that rule's own
`windows` in the snapshot. A target-keyed grant would also lift every sibling rule and the App
Blocker row for the same app, which is exactly what `liftsUnlockedRulesToo: false` forbade — so
that knob was dropped rather than implemented twice.

> **The plan's one wire-contract change — DONE.** `pushWebBlocklist`'s per-entry `pausedUntil` is
> gone; the per-site pause is a `WEBSITE` grant on `pushTemporaryUnblocks`, so there is one
> mechanism for "this target is dormant until T" instead of two. Native ignores the old key for
> free (nothing reads it), so a downgrade cannot resurrect a stale pause, and `migrateWebPauses`
> carries a live one across once at bootstrap. **Call it out in the release notes.**
>
> The per-entry shape is now `{pattern, matchType}` — two keys.

> **M8 was pulled forward of M2**, which is still unbuilt, so it authored `bypassLedger` itself —
> in exactly M2.2's shape, with the `kind` discriminator, writing only `OVERRIDE`. M2.2 adds the
> `EMERGENCY` preset to the same store; it does **not** create the key. There is no waiting-room
> gate yet: M2.1 inserts one in front of `grant()` with no contract change.

---

## Event types

**Today: 9**, and **none is inert** — every declared `ChannelEvents` constant has at least one
native emitter *and* at least one Dart consumer. The inert `detection` and `foregroundChanged`
constants were deleted once already for exactly this reason; the pattern has not returned. Keep it
that way.

Only `serviceStatus` is sticky (replayed to a late subscriber); every other type is dropped when
no sink is attached. M2 adds none, and **M8 added none either — the count stays 9.**

| `type` | Payload | Status |
|---|---|---|
| `blockScreenAction` | `{action: "OPEN_APP" \| "GO_HOME" \| "UNBLOCK" \| "DISMISS", referenceType, referenceId, preview: Bool}` | **shipped** M1 (`UNBLOCK` handled by M8) |
| `ruleBoundary` | `{atMs: Long}` — a pushed window opened or closed; Dart recomputes and re-pushes | **shipped** M3 |
| `blocked` (existing event, extended) | gained `reason: "PLAN" \| "APP_BLOCK" \| "SCHEDULE" \| "DAILY_LIMIT"`, and `platformId: "rule"` for a rule's HOME bounce | **shipped** M3 |
| ~~`usageLimitReached`~~ | ~~`{ruleId, targetId}`~~ | **never shipped** — replaced by the `blocked` extension above. Do not reintroduce it |
| ~~`temporaryUnblockExpired`~~ | ~~`{targetType, targetId}`~~ | **never shipped** (M8). Detoxo is single-process, so the Dart isolate is alive in exactly the states this event would have had a sink to reach; `UnblockCubit` arms a one-shot timer (the `RulesCubit` idiom) and holds a DERIVED `active` list so the lapse changes `props`. Native enforces the expiry regardless. Do not reintroduce it |
| `nudgeShown` | `{package: String, elapsedMs: Long, thresholdMs: Long}` | **shipped** M7 |


---

## Hive — `StoreKeys`

**Today: 18 constants** in [`lib/core/storage/local_store.dart`](../../lib/core/storage/local_store.dart),
of which **16 are live** — `premiumDevUnlock` and `dismissedNotices` are declared with zero
usages. All are plain (non-secret) JSON strings in the `detoxo` box; **`pin_config` remains the
only secure-storage key**, and this plan adds no second one. M8 added two; M2 adds `waitingRoom`,
so the plan lands at **19**.

| Key constant | String | Shape | Retention | Milestone |
|---|---|---|---|---|
| `rules` | `rules` | JSON array of rule documents | capped at 50 rules | M3 — **shipped** |
| `usageDaily` | `usage_daily` | `{days: {"dd-MM-yyyy": {…}}}` | **90 days, prune on write** | M4 — **shipped**, see [`code_docs/28`](../code_docs/28-insights.md) §4 |
| `onboardingProgress` | `onboarding_progress` | step + survey answers + selection | single doc | M6 — **shipped** (completion lives on `AppSettings.onboarded`) |
| `waitingRoom` | `waiting_room` | config + `grants[]` | last 20 grants | M2.1 — *forward spec* |
| `bypassLedger` | `bypass_ledger` | `{config, entries[{kind, atMs, untilMs, ruleId?, reason?}]}` | last 50 | **M8 — shipped.** M8 was pulled forward of M2, so it authored this key itself, in exactly M2.2's shape and with the `kind` discriminator; it writes only `OVERRIDE`. `untilMs` is the one addition — the lift's window has to live somewhere and it is a chosen value, not a derived one. `liftsUnlockedRulesToo` was **dropped**: the override is scoped to the rule, so the knob falls out for free. M2.2 adds the `EMERGENCY` preset to this same list |
| `temporaryUnblocks` | `temporary_unblocks` | `{grants[{targetType, targetId, startMs, endMs, cancelledMs, source}]}` | last 50 | **M8 — shipped.** `source` is `WALL \| BLOCKLIST_ROW`; there is no `OVERRIDE` source, because an override is not a grant |

> **Two records this plan once specified and never built.** `suppressedApps` (M5) — the suppressed
> set is derived live and never stored, see the M5 delta above. `softNudge` (M7) — three scalars
> ride on `AppSettings` instead. Neither exists in `local_store.dart`; neither should be
> reintroduced.

**No `StoreKeys` entry for the category catalog** — it is a bundled asset
(`assets/config/app_categories.json`), not user state. **No entry for the block-screen style**
either: native owns it (`blockScreenStyle` hydrates the editor).

### Rules that apply to every record here

1. **Enums persist as stable name strings**, never ordinals. A reorder must not remap saved state;
   a rename is a migration.
2. **Bounded collections prune on write**, not on read. An unbounded list inside a single JSON
   document is a slow leak.
3. **Derived data is not stored.** The suppressed-app set (M5) is a projection of rules and
   blocklists; storing it would create a second source of truth that can disagree with the first.
   Same for `expiresAt` / `cooldownEnd` in M2.2. *M5 is the worked example — it is the rule that
   killed that milestone's original design.*
4. **Every new day key uses `dd-MM-yyyy`** — see the hazard below.
5. Absent record ⇒ documented default. Every reader must work on a fresh install and on an
   upgrade from a version that never wrote the key.

---

## Native SharedPreferences

**Three prefs files already exist**, not two — the split the original plan deferred "until
measurement" has happened:

| File | Keys | Contents |
|---|---|---|
| `detoxo_engine_prefs` | **45** | the hot set: plan, counters, blocklists, Conscious bank, nudge config — **two owner classes**, `ConfigStore` (32) and `ContentCounterStore` (13, all `cc_*`-prefixed) |
| `detoxo_platforms_config` | 1 | `platforms_config_json` (~31 KB) |
| `detoxo_rules_snapshot` | 1 | `rules_json` (~45–175 KB) |

The two big blobs live apart so hot-path counter writes — which flush every few seconds — stop
re-serialising them. `ConfigStore`'s `init {}` performs a one-time idempotent migration of both
keys out of `detoxo_engine_prefs`.

| Key | Type | Default | File | Milestone |
|---|---|---|---|---|
| `block_screen_style` | String (JSON) | `""` | engine_prefs | M1 — **shipped** |
| `rules_json` | String (JSON array) | `null` | **rules_snapshot** | M3 — **shipped** |
| `next_boundary_ms` | Long | `0` | engine_prefs | M3 — **shipped** |
| `suppress_notifications` | Boolean | `false` | engine_prefs | M5 — **shipped** (replaces the specified `suppressed_packages` StringSet, which was never built) |
| `nudge_enabled` | Boolean | `false` | engine_prefs | M7 — **shipped** |
| `nudge_packages` | StringSet | `∅` | engine_prefs | M7 — **shipped** |
| `nudge_step_ms` | Long | `300000` | engine_prefs | M7 — **shipped**, clamped 1–60 min |
| `nudge_daily_cap` | Int | `4` | engine_prefs | M7 — **shipped**, clamped 1–50 |
| `temporary_unblocks_json` | String (JSON array) | `null` | engine_prefs | M8 — **shipped** |
| `pending_unblock` | String | `null` | engine_prefs | M8 — **shipped**; read-and-cleared by `takePendingUnblock` |

**Hot-path rule.** Native never reads `SharedPreferences` per accessibility event. Every one of
these keys is mirrored into a `@Volatile` field on push, following the existing `masterOn`,
`pausedUntil`, `activePlan`, `enabledPlatformIds`, `protectedPkgs`, `blockedApps`, `homePkgs`,
`consciousBank` mirrors.

---

## Manifest delta

**One change across all nine milestones, and it has shipped:**

```xml
<service
    android:name=".notifications.DetoxoNotificationListener"
    android:exported="false"
    android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
    <intent-filter>
        <action android:name="android.service.notification.NotificationListenerService" />
    </intent-filter>
</service>
```

`BIND_NOTIFICATION_LISTENER_SERVICE` is held by the *system*, not requested by us — it is not a
`<uses-permission>`.

**No new `<uses-permission>` anywhere in this plan** — M8 included. Everything else is already declared:

| Needed by | Permission | Status |
|---|---|---|
| M0.2, M3, M4 | `PACKAGE_USAGE_STATS` | already declared, already granted through the funnel; read by `rule_sync` (M3) and the insights rollups (M4) — no manifest change was needed |
| M1, M7 | `SYSTEM_ALERT_WINDOW` | already declared (the counter bubble uses it); M1 and M7 are the second and third windows to draw with it |
| M3 | `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED` | already declared |

`ACTIVITY_RECOGNITION` is **not** added — the sensor half of the autofocus source doc is dropped in
M7 precisely to avoid it. Verified absent. `QUERY_ALL_PACKAGES` stays absent; the existing
`<queries>` MAIN filter already makes `installedApps` work.

---

## `pubspec.yaml` delta

**None.** Every package this plan needs is already declared:

| Need | Package | Status today |
|---|---|---|
| Boundary notifications (M3) | `flutter_local_notifications` | declared, **still unwired** — zero imports in `lib/` |
| Time/date formatting (M3, M4) | `intl` | in use |
| Rule ids (M3) | `uuid` | in use |
| Set/list helpers (M0, M3) | `collection` | declared, **still unwired** — zero imports |
| Per-tab shells (M6) | `go_router` | in use — though M6 shipped **without** `StatefulShellRoute`; the router stayed flat |

Explicitly **not** added: `drift` (already declared and unused — see below), `pedometer`,
`sensors_plus`, `workmanager`, `firebase_messaging`, `purchases_flutter`, plus the paywall,
attribution and analytics SaaS the source set uses; `share_plus`, `qr_flutter`, `mobile_scanner`,
`video_player`, `rxdart`, `shared_preferences`, `flutter_riverpod`.

---

## Two pre-existing hazards this plan must not propagate

Both were flagged before M0 and **both are still live** as of 2026-09-04.

### 1. Day-key format is inconsistent today

Three producer sites, two agreeing:

| Site | Format |
|---|---|
| native `engine/DateKeys.kt` | `dd-MM-yyyy` |
| `lib/core/utils/day_signature.dart` | `dd-MM-yyyy` |
| `WebBlockStatsRepositoryImpl._todayKey()` | **`yyyy-MM-dd`** |

Two formats for one concept in one app. **Every day key introduced by this plan uses
`dd-MM-yyyy`** and goes through `daySignature()`.

The outlier is a hand-rolled `'${now.year}-$m-$d'` that bypasses `intl` entirely — so a grep for
`DateFormat(` will never surface it. Blast radius is contained: it keys only the Dart-local
`web_block_stats` blob, which is never cross-read against native's `web_block_date`. It is a
latent inconsistency, not a live corruption, and `daily_stats.dart` already documents it in-source
as a known trap. Normalising it is an EVO-scale fix with a one-time migration — noted here,
deliberately not folded into a milestone.

### 2. `drift` is declared and imported by nothing

`drift ^2.33.0` + `drift_dev ^2.33.0` + `sqlite3_flutter_libs ^0.6.0+eol` are in `pubspec.yaml`;
`grep -rn 'package:drift' lib/ test/` still returns zero hits. Roughly 1.63 MB per user of dead
weight, plus a `build_runner` builder with nothing to generate.

Note they also escaped the pruning pass that produced pubspec's other annotations — the file
carries explicit "we deliberately do NOT depend on X" comments for `cupertino_icons`, `dio`/`http`,
`google_mobile_ads`, `workmanager`, `home_widget` and others, but none for these three.

The storage decision for this plan keeps them unused — **no milestone here introduces drift**, and
every entity the suggestion set models as a drift table is re-modelled above as a Hive JSON
record. Removing the three dependencies is a clean EVO-scale cleanup and is deliberately out of
scope.

---

## Cumulative surface

Measured 2026-09-06. "Today" is eight milestones in; "after" adds only M2.

| Surface | Pre-M0 | Today | After M2 + M8 |
|---|---|---|---|
| MethodChannels | 1 | **1** | **1** |
| EventChannels | 1 | **1** | **1** |
| Command methods | 37 | **53** | 53 |
| Event `type` values | 6 | **9** | 9 |
| Hive `StoreKeys` | 13 | **18 (16 live)** | 18 |
| Secure-storage keys | 1 | **1** | **1** |
| `detoxo_engine_prefs` keys | ~30 | **48** | 48 |
| Native prefs files | 2 | 3 | 3 |
| `<uses-permission>` | 13 | **13** | **13** |
| Manifest services | 2 | 3 | 3 |
| pubspec dependencies | 42 | **42** | **42** |
| Processes | 1 | **1** | **1** |
| FlutterEngines | 1 | **1** | **1** |

The point of this table is the columns that do not move.

## Validation for the contract itself

Each check is a command, so this file can be re-verified rather than re-argued.

- [ ] `grep -roh 'com\.errorxperts\.detoxo/[a-z]*' docs/plan_docs/ | sort -u` yields exactly
      `/commands` and `/events`
- [ ] Every method named in a milestone doc appears in this doc's tables, and vice versa
- [ ] Every persisted record named in a milestone doc appears in the Hive or prefs table here
- [ ] Every declared `ChannelEvents` constant has a native emitter. The `-A2` matters — four of the
      nine `post(` calls put the type on the next line, and without it they read as inert:
      ```bash
      grep -rh 'ServiceEventBus.post(' -A2 android/app/src/main/kotlin/ \
        | grep -o '"[a-zA-Z]*"' | tr -d '"' | sort -u
      ```
- [ ] `grep -rin 'drift\|revenuecat\|superwall\|adjust\|amplitude\|firebase_messaging\|workmanager'
      docs/plan_docs/` returns only exclusion rationale
- [ ] **No prior-vendor namespace anywhere** — not in `lib/`, `android/`, `tool/`, `test/`, and
      not in these plan docs either. The brackets are deliberate — they grep identically but stop
      the check from matching itself. Both `o`s need one, or the second alternative becomes a hit
      for the first.
      ```bash
      grep -rinE '[o]pal|[w]ith[o]pal|[y]ourapp' docs/plan_docs/ lib/ android/ tool/ test/
      ```
      (This file used to fail this check — its own channel-collapse table carried six, while the
      line below it forbade them. Refer to the source app by role, never by name.)
- [ ] **The counts above still hold.** They are the first thing to rot:
      ```bash
      sed -n '/class ChannelMethods/,/^}/p' lib/core/constants/channel_constants.dart | grep -c 'static const String'   # 52
      sed -n '/class ChannelEvents/,/^}/p'  lib/core/constants/channel_constants.dart | grep -c 'static const String'   # 9
      sed -n '/class StoreKeys/,/^}/p'      lib/core/storage/local_store.dart         | grep -c 'static const String'   # 18
      ```
- [ ] Nothing here claims a contract that does not exist:
      `grep -rn 'pushSuppressedApps\|suppressed_packages\|softNudge\|soft_nudge\|usageLimitReached\|activeFromMs\|temporaryUnblockExpired\|liftsUnlockedRulesToo' lib/ android/`
      returns nothing
