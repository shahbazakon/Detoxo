# M8 — Locked rules & per-target unblock

- Status: **shipped** — engineering doc [`code_docs/31-locked-rules-and-unblock.md`](../code_docs/31-locked-rules-and-unblock.md);
  on branch `sensitive_protection` (commit pending at the time of writing).
  **Shipped with seven deliberate deviations — see the box below; the plan text under it is the
  original and is kept for the record.**
- Source: [C2 Managed Rules & Self-Bypass](../suggestion_docs/flutter-migration/C-family-school/C2-managed-rules-and-self-bypass.md) (mechanics, re-pointed at self-authority) · [B4 §temporary_unblocks](../suggestion_docs/flutter-migration/B-blocking/B4-waiting-room.md) · [B7 `offersUnblock`](../suggestion_docs/flutter-migration/B-blocking/B7-overlay-block-screen.md)
- Feature areas: `lib/features/limits/rules/` (locked flag), new `lib/features/limits/unblock/`, native `engine/UnblockRegistry.kt`
- Effort: **M** (one native check, one grant model, one quota ledger — much of it shared with M2)
- Blocked by: M1 (the Unblock button), M2 (the waiting room + the ledger), M3 (rules)

> ### Shipped deltas (M8) — read this before citing the text below
>
> M8 was **pulled forward of M2**, which is still unbuilt. It therefore authors
> `StoreKeys.bypassLedger` itself, in exactly M2.2's specified shape (`config` + a `kind`
> discriminator), writing only `OVERRIDE`; `EMERGENCY` stays reserved so M2.2 adds a preset rather
> than renaming a persisted key. **There is no waiting-room gate** — M2.1 inserts one in front of
> `grant()` later with no contract change.
>
> 1. **The override lifts a RULE, not its targets.** `requestOverride` does *not* call
>    `unblock.grant(rule.selection, …)`. A target-keyed grant on `com.instagram.android` would also
>    lift every sibling rule on Instagram **and** the App Blocker row — it cannot express this
>    doc's own `liftsUnlockedRulesToo: false` default. Instead `resolveSnapshot` subtracts the lift
>    window from that rule's own `windows` (splitting them), so native re-arms at the far edge by
>    its existing long compare with Flutter dead. Zero Kotlin, zero wire, and the knob falls out for
>    free — so it was dropped from `config` rather than implemented twice.
> 2. **`locked` implies `strict`, and the `pushRules` snapshot gains no key.** A locked rule a
>    two-minute Pause lifts would be theatre. `locked` / `lockScope` stay Dart-side.
> 3. **The check is at the four non-strict branches, not "one place above every block branch."**
>    Native only has `pkg` at the privacy guard; the reel and web ids appear ~150 lines later. The
>    strict arm deliberately never reads the registry — *that absence is the guarantee*, and it is
>    stronger than the wire flag an earlier draft of this plan implied.
> 4. **No `temporaryUnblockExpired` event.** Detoxo is single-process, so the Dart isolate is alive
>    in exactly the states a native event would have had a sink to reach. `UnblockCubit` arms the
>    one-shot `RulesCubit._armTimer` idiom instead, and holds a **derived `active` list** so the
>    lapse actually changes `props`. Events stay at **9**.
> 5. **The wall hand-off is a consumable prefs key**, `takePendingUnblock`, not the
>    `blockScreenAction` event: on a cold start the EventChannel sink does not exist when the action
>    is posted. So M8 adds **two** commands (51 → **52**), not one.
> 6. **`UnblockRegistry` is monotonic.** The signature in §Part A below (`isUnblocked(type, id,
>    nowMs)`, and its `WebBlockEngine.kt:61` citation) predates EVO-048, which had already moved the
>    per-site pause to `elapsedRealtime`. Shipping it as written would have re-opened a two-tap
>    Settings-clock bypass.
> 7. **`locked ⟹ strict` forced EVO-030's website gap closed.** `blockingForHost` gained
>    `strictOnly` and the browser arm now runs during a Pause when `hasStrictHostRules()` — otherwise
>    a locked rule's sites were free for one tap while its apps cost an override.
>
> 8. **The refusal set is wider than `setEnabled` / `delete` / `snooze`.** `LockGuard` also refuses
>    a schedule change and a loosened budget: freezing a locked rule's *targets* while leaving its
>    hours and its threshold editable is a two-tap escape that costs no override.
> 9. **An override is refused when the rule is not enforcing.** It buys a window starting now, so
>    spending one on a closed schedule burns a scarce resource and lifts nothing.
>
> Also: **a locked rule is never unlockable in-app** (no override buys a permanent unlock), the
> quota period is a **rolling** 7 days on the wall clock rather than a calendar period with a
> monotonic anchor (see the amended risk note), and the override UI is a tile plus two sheets inside
> the rule editor rather than a routed screen — so `Routes` is unchanged.

Two halves of one tension: making a rule **harder to escape**, and giving the user a **legitimate,
rationed, per-target way out** so they don't disable everything instead.

Shipping only the first half produces an app people uninstall. Shipping only the second produces
an app that never holds. They go together, which is why they are one milestone.

## Why now

**Every escape hatch in Detoxo is global, and every rule is freely disableable.**

| Escape today | Scope | Rationed? |
|---|---|---|
| Pause (2–10 min) | **everything** | no |
| Unblock N reels (2–20) | **everything** | no |
| One Reel | **everything** | no |
| Per-site `pausedUntil` | one host | no |
| Toggle any blocklist entry off | that entry | no |

So a user who needs Instagram for two minutes to answer a DM has exactly one option: **lift
protection on everything**. The product's own framing — "you don't have to quit the apps you love,
just the bottomless part" — is undermined by an escape model that is all-or-nothing.

`WebBlockEngine.kt:61` is the one place Detoxo already does this right:

```kotlin
if (now < r.pausedUntil) continue   // per-site pause window
```

One target, dormant until a timestamp, enforced natively so it re-arms even if the app is never
reopened. M8 generalises exactly that line to reels and apps, and adds the commitment side that
makes it safe to have.

## What the user gets

- **Unblock this app for 15 minutes** — from the wall, or from a blocklist row. Everything else
  stays protected. It expires by itself.
- **Locked rules** — mark a rule locked and it has no off switch. Not greyed out; *absent*. To lift
  one you spend an **override** from a small quota, pick a reason, and choose a window.
- **One ledger** — overrides and the emergency pass are the same rationed thing with different
  presets, so there is one number to understand, not three.

---

## Part A — Per-target temporary unblock

### Algorithm & control flow

```
grant(target, duration, source):        // source: WALL | BLOCKLIST_ROW | OVERRIDE
    // friction first — M2's waiting room gates this, it is not a second gate
    if (waitingRoom.enabled) { await waitingRoom.run(target); if (abandoned) return }

    u = TemporaryUnblock(
          targetType: REEL | APP | WEBSITE,
          targetId:   platformId | package | host,
          startMs:    now,
          endMs:      now + duration,
          cancelledMs: null,
          source:     source)
    ledger.append(u); prune()
    push()                              // pushTemporaryUnblocks

activeAt(now) = unblocks.where {
        it.cancelledMs == null && it.startMs <= now && now < it.endMs }

endEarly(u):  u.cancelledMs = now; push()        // "I'm done" — give protection back
sweep(now):   drop where cancelledMs != null || endMs <= now
```

Native side — **one check, one place**, placed immediately after the privacy guard and before every
block branch so it covers reels, apps and websites uniformly:

```kotlin
// engine/UnblockRegistry.kt — Android-free, JVM-tested
fun isUnblocked(type: String, id: String, nowMs: Long): Boolean =
    entries.any { it.type == type && it.id == id && nowMs < it.endMs }
```

`entries` is a `@Volatile` list replaced wholesale on push, mirroring `WebBlockEngine.rules`.
Expiry is enforced **natively** — the grant lapses on time even if the Flutter app is never
reopened, which is the whole reason the web blocker's `pausedUntil` works.

When the last entry for a target expires, native posts `temporaryUnblockExpired` so any open Dart
UI stops showing a countdown that has already ended.

### Durations

Reuse what exists. The web blocker's per-site pause sheet already offers **5 / 15 / 30 / 60
minutes**; use the same chips, the same sheet component, the same wording. A second duration
vocabulary would be a second thing to learn for no gain.

### Consolidating the two mechanisms

`pushWebBlocklist`'s per-entry `pausedUntil` and this registry express the same concept. Two
mechanisms for one idea is exactly what M0.1 tells the executor to delete when it found
`AppDomainCatalog` duplicating the catalog — the same standard applies here.

**Step: migrate the web blocker's per-site pause onto `pushTemporaryUnblocks`** and drop
`pausedUntil` from the `pushWebBlocklist` payload. `WebBlockEngine.matchHost` then asks
`UnblockRegistry.isUnblocked("WEBSITE", host, now)` instead of checking its own field, and
`Rule.pausedUntil` disappears. One-time migration on read: any stored web entry with a future
`pausedUntil` becomes a `TemporaryUnblock` row.

This is a **wire contract change** to a shipped command. Native must accept the old payload shape
(ignoring `pausedUntil`) for one release so a downgrade cannot resurrect a stale pause.

---

## Part B — Locked rules

### The adaptation

C2's mechanics are entirely local; only its *authority* needs a server. Detoxo has no school and no
family organiser — but it does have the authority the product is actually built around, and already
implements elsewhere in the PIN lock and uninstall protection: **past-you.**

| C2 | Detoxo |
|---|---|
| `LocalManagedAuthority { School, Family }` | `LockAuthority { self }` — one value, kept as an enum so the shape survives |
| Rule pushed by a server, deleted when the server drops it | Rule authored locally, marked `locked: true` at creation |
| Non-disableable because an authority says so | Non-disableable because you chose that when you made it |
| `SelfBypassStatus{remaining, limit, period, resetsAt}` from the backend | Computed locally by `effectiveRemaining` — C2's *offline fallback* becomes the primary path |
| "Sick Day Pass" | **"Override"** |

Everything else transfers unchanged: the quota, the reason picker, the window, the
`bypassesPersonalRules` flag, and the non-disableable invariant.

### The invariant that matters

C2 states it plainly and it is the single most important line in that document:

> *the UI must not expose enable/disable/delete for a rule whose source == managed. Any toggle
> attempt is rejected in the domain layer, not the UI only.*

Concretely, in Detoxo:

- `RuleRepository` exposes **no mutate use-case** that accepts a locked rule. `setEnabled`,
  `delete` and `snooze` return a `LockedRuleError` rather than silently no-opping.
- `RuleTile` renders locked rules with **no toggle and no swipe action** — absent, not disabled.
  A greyed-out switch is an invitation to keep tapping.
- The only path that lifts a locked rule is an override, which spends quota.

Hiding it in the UI alone is not enough: the cubit is reachable from other features today (five of
them already reach `settings_cubit`, per the boundary baseline), and a rule that can be disabled
through a side door is not locked.

### Lock scope

C2's `LocalManagedBlockScope { AllApps, DistractingApps }` maps directly onto M0.1's catalog:

| `LockScope` | Meaning |
|---|---|
| `selection` | Exactly the rule's own selection (the default) |
| `distracting` | Every package the catalog marks `distracting` — so the rule keeps holding as new apps are installed |

`distracting` is the genuinely useful half: a lock that only covers the apps you listed on Tuesday
is defeated by installing a new one on Wednesday.

### Quota

```
effectiveRemaining(now):
    periodStart = startOfCurrentPeriod(config.period, now)     // DAY | WEEK, local tz
    used = ledger.count { it.kind == OVERRIDE && it.atMs >= periodStart }
    return max(0, config.limit - used)

canOverride(now) = effectiveRemaining(now) > 0

requestOverride(rule, reason, startMs, endMs, now):
    validate: effectiveRemaining(now) > 0
              startMs < endMs
              reason != null
              endMs - startMs <= config.maxWindow
    // C2 §4c step 5: every one of these is checked BEFORE anything is written
    ledger.append(Bypass(kind: OVERRIDE, atMs: now, ruleId: rule.id, reason: reason))
    unblock.grant(rule.selection, endMs - startMs, source: OVERRIDE)
```

Defaults — these are Detoxo product decisions, not recovered constants (C2's came from a server):

| Knob | Default |
|---|---|
| `limit` | **2** |
| `period` | `WEEK` |
| `maxWindow` | **60 min** |
| `liftsUnlockedRulesToo` | `false` (C2's `bypassesPersonalRules`) |

Reasons — C2's six, kept verbatim because making the user name the reason is the point:
`FEELING_SICK`, `MEDICAL_APPOINTMENT`, `FAMILY`, `SCHEDULE_CHANGE`, `WRONG_SCHEDULE`, `OTHER`.

### One ledger, not three

The emergency pass ([M2.2](03-M2-friction-and-passes.md)) and the override are the same rationed
thing at different scopes. They share `StoreKeys.bypassLedger` and one `BypassLedger` type with two
presets:

| Preset | Scope | Quota | Reason | Window |
|---|---|---|---|---|
| `EMERGENCY` | everything | 1 / 7 days | optional | fixed 1 h |
| `OVERRIDE` | one locked rule | 2 / week | **required** | chosen, ≤ 60 min |

> **M2 ships the ledger; M8 adds the second preset.** M2.2 must build `BypassLedger` with a `kind`
> discriminator from the start — **not** an `emergencyPass`-only store that M8 then has to rename.
> A persisted-key rename is a storage contract change and a one-way door.

---

## Data model

Hive. Enums as **stable name strings**.

`StoreKeys.temporaryUnblocks`:

```jsonc
{
  "grants": [                          // bounded: last 50, prune on write
    { "targetType": "APP",             // REEL | APP | WEBSITE
      "targetId": "com.instagram.android",
      "startMs": 1756742400000,
      "endMs":   1756743300000,
      "cancelledMs": null,
      "source": "WALL" }               // WALL | BLOCKLIST_ROW | OVERRIDE
  ]
}
```

`StoreKeys.bypassLedger` (shared with M2.2):

```jsonc
{
  "config": { "overrideLimit": 2, "overridePeriod": "WEEK",
              "overrideMaxWindowMs": 3600000, "liftsUnlockedRulesToo": false },
  "entries": [                         // bounded: last 50
    { "kind": "OVERRIDE",              // EMERGENCY | OVERRIDE
      "atMs": 1756742400000,
      "ruleId": "uuid",                // null for EMERGENCY
      "reason": "SCHEDULE_CHANGE" }    // null allowed for EMERGENCY
  ]
}
```

Rule documents ([M3](04-M3-rules-engine.md)) gain two fields — **no new key**:

```jsonc
{ "locked": true, "lockScope": "DISTRACTING" }   // SELECTION | DISTRACTING
```

Native `detoxo_engine_prefs` gains `temporary_unblocks_json`.

**Derive, don't store** (M2.2's rule, applied here): `effectiveRemaining`, `resetsAt` and
`canOverride` are computed from the ledger. Caching a `remaining` int is how it drifts out of sync
with the entries that produced it.

## Channel delta

| Method | Args | Returns |
|---|---|---|
| `pushTemporaryUnblocks` | `{json: String}` — `[{targetType, targetId, endMs}]` | `true`; no-op on null/non-array; skips when unchanged |

New event `type`: **`temporaryUnblockExpired`** — `{targetType, targetId}`.

`blockScreenAction`'s `action` gains **`"UNBLOCK"`** (see [M1](02-M1-intervention-wall.md)); no new
event for it.

Locked rules need **no new command** — `locked` and `lockScope` ride the existing `pushRules`
snapshot, and a lifted lock is simply a temporary unblock over that rule's targets.

## Module layout

```
lib/features/limits/unblock/
├── domain/entities/{temporary_unblock,bypass_entry,bypass_config,override_reason}.dart
├── domain/repositories/{temporary_unblock_repository,bypass_ledger_repository}.dart
├── domain/usecases/{grant_unblock,end_unblock_early,effective_remaining,request_override}.dart
├── data/repositories/*.dart
└── presentation/{unblock_cubit.dart, unblock_sheet.dart, override_screen.dart}

android/.../engine/UnblockRegistry.kt        # Android-free; JVM-tested
```

Exported from `lib/features/limits/limits.dart`. `effectiveRemaining` and `activeAt` are **pure
static methods** — the `StreakCubit.advance` pattern.

## Reuse map

| Existing | Take |
|---|---|
| [`engine/WebBlockEngine.kt:61`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt#L61) | `if (now < r.pausedUntil) continue` — the whole idea, generalised. `UnblockRegistry` is its replacement, not its sibling |
| `WebBlockEngine`'s `@Volatile` list + `setBlocklist(json)` replace | The push/parse/hot-path shape |
| The per-site pause sheet (5/15/30/60 chips) | The exact durations, sheet and copy |
| `flutter_slidable` (declared, used on web rows) | The blocklist-row swipe affordance for "unblock for…" |
| M2's waiting room | The friction. **Do not add a second gate** |
| M2.2's `BypassLedger` | The ledger. **Do not add a second store** |
| `PinConfig`'s lockout ladder | Deriving state from timestamps + constants |
| EVO-012 (per-site pause, done 2026-08-17) | The shipped precedent for "a dormant window native re-arms on its own" |

## Steps

1. `UnblockRegistry.kt` + JVM tests; the `isUnblocked` check wired in after the privacy guard and
   above every block branch.
2. `pushTemporaryUnblocks` arm + `temporary_unblocks_json` + the `temporaryUnblockExpired` post.
3. Dart grant model, repository, cubit; the unblock sheet reusing the per-site chips.
4. Wire M1's Unblock button (`offersUnblock` → `blockScreenAction: "UNBLOCK"`) and the blocklist-row
   swipe action, both through M2's waiting room.
5. **Migrate the web per-site pause** onto the registry; drop `Rule.pausedUntil`; keep native
   tolerant of the old payload for one release.
6. Add `locked` + `lockScope` to the rule document and the snapshot; resolve `DISTRACTING` through
   M0.1 at snapshot time.
7. Enforce non-disableable in `RuleRepository` (return `LockedRuleError`, do not no-op) and remove
   the toggle from `RuleTile` for locked rules.
8. Generalise `BypassLedger` with the `OVERRIDE` preset; override screen with the reason picker,
   remaining/limit, and the reset date.
9. Tests, then `/docs-sync` — 03, 04, 06, 07, 09, 18 + `info_docs/02` and FAQs.

## Risks & ceilings

- **Clock tampering.** *Decided, and the decision differs from the upgrade path named here.* The
  **registry** is monotonic (EVO-048's rule, inherited): a grant cannot be extended by moving the
  clock. The **quota** stays on the wall clock, as a rolling 7-day window:
  `ponytail: moving the system clock forward mints quota — the ceiling already accepted at
  pin_config.dart and in WebBlockEngine. Not worth hardening here alone: the same jump already walks
  the user out of every SCHEDULE window and resets every daily budget. Harden at that shared now,
  once, or not at all.` EVO-015's anchor guards a ≤24 h same-boot deadline and does not transfer to
  a 7-day age — `bootCount` changes on every reboot, so the leg would be unreadable most of the time
  and, read strictly, would freeze the quota forever after the first restart.
- `ponytail: UnblockRegistry is a linear scan per event; fine at 50 grants, and the prune keeps it
  there.`
- **Do not stack gates.** An override already costs quota, a reason and a wait. Do not also require
  the PIN — the PIN guards settings; the quota guards the rule.
- **A lock the user cannot ever escape is a lock they escape by uninstalling.** The quota exists so
  the honest path is always available. Never ship `limit: 0`.
- **Locked rules and uninstall protection compound.** With device admin on and every rule locked, a
  frustrated user has no in-app exit. The settings copy must say plainly how to unwind both.
- **Wire contract change** in step 5 — call it out in the release notes; it is the only one in the
  whole plan.

## Validation

- [ ] `bash tool/dev.sh precommit` passes, `UnblockRegistryTest.kt` included
- [ ] Unblocking Instagram leaves reels blocked in **every other** app, and web blocking untouched
- [ ] A grant expires natively with the app force-stopped, and survives a reboot with the correct
      remaining time (`ConfigStore` + `BootReceiver` path)
- [ ] "End early" restores protection immediately, not at `endMs`
- [ ] No domain path can disable, delete or snooze a locked rule — asserted in a test, not just
      absent from the UI
- [ ] `lockScope: DISTRACTING` picks up a newly installed distracting app without editing the rule
- [ ] Quota tests: `remaining == 0` refuses before writing; an inverted window refuses; a window
      over `maxWindow` refuses; the period rolls at local midnight / week start; every one of the
      six reasons round-trips its wire token
- [ ] Emergency pass and override share one ledger — grep for a second store
- [ ] After step 5, no `pausedUntil` remains in `WebBlockEngine`; a stored future pause migrates
- [ ] `pubspec.yaml` unchanged; no new permission
- [ ] `tool/boundaries_baseline.txt` line count ≤ 8

## Target files

**New** — `android/.../engine/UnblockRegistry.kt` · `android/app/src/test/UnblockRegistryTest.kt` ·
`lib/features/limits/unblock/**` · `test/temporary_unblock_test.dart` · `test/override_quota_test.dart`

**Edited** — `android/.../accessibility/DetoxoAccessibilityService.kt` (one guard) ·
`android/.../engine/WebBlockEngine.kt` (drop `pausedUntil`) · `android/.../channels/CommandHandler.kt` ·
`android/.../engine/ConfigStore.kt` · `android/.../overlay/BlockScreenRenderer.kt` (Unblock button) ·
`lib/core/constants/channel_constants.dart` · `lib/core/storage/local_store.dart` ·
`lib/features/limits/rules/**` (locked flag + domain refusal) ·
`lib/features/limits/web_blocker/**` (pause migration) · `lib/features/limits/limits.dart` ·
`lib/core/di/injector.dart` · `lib/core/navigation/{routes,app_router}.dart`
