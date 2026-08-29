# M2 — Friction and passes: waiting room + emergency pass

- Status: **planned**
- Source: [B4 Waiting Room](../suggestion_docs/flutter-migration/B-blocking/B4-waiting-room.md) · [D4 Emergency Pass](../suggestion_docs/flutter-migration/D-insights-engagement/D4-emergency-pass.md) · quota mechanic from [C2](../suggestion_docs/flutter-migration/C-family-school/C2-managed-rules-and-self-bypass.md)
- Feature areas: `lib/features/limits/waiting_room/`, `lib/features/limits/emergency_pass/`
- Effort: **M** (both pure Dart; no native change beyond one push)
- Blocked by: M3 for the "unblock a rule" entry point; M2.2 ships standalone
- Blocks: **M8** — which reuses this milestone's waiting room as its only friction gate and this
  milestone's bypass ledger as its only quota store

Both features are **fully local** and need no backend. D4 is the cleanest document in the entire
suggestion set — a two-column table and every other value computed.

## Why now

Detoxo's escape hatches are **instant and unlimited**. Pause is a bottom sheet away (2–10 minutes,
2-minute steps, default 4) and can be re-tapped forever. Unblock releases 2–20 reels on a dial.
One Reel is a single tap. There is no cost, no delay, and no ration anywhere in the product.

That is the gap a commitment device cannot afford. The PIN lock exists precisely because the app
accepts that future-you will try to undo present-you's decision — but the PIN guards *settings*,
not the escape hatches, which are one tap from the dashboard by design.

Friction is the cheapest known intervention: the wait itself is the mechanism. And a rationed pass
turns "I can always turn it off" into "I have one of these, and using it costs me a week."

## What the user gets

- **Waiting room** — choosing Pause or Unblock now opens a countdown you have to sit through.
  Back out early and nothing is granted. Two resistance settings: a fixed wait, or one that grows
  each time you come back within the same stretch.
- **Emergency pass** — a genuine break-glass: hold the button, every block lifts for an hour,
  and the pass is gone for seven days. Visible cooldown, visible history.

---

## M2.1 — Waiting room

### Algorithm & control flow

```
enter(request):                              // Pause | Unblock(n) | OneReel | RuleUnblock(id)
    mode = config.resistanceMode             // standard | increasing
    wait = mode == standard
             ? config.baseWait
             : config.baseWait + batchCounter.get() * config.escalationStep
    targetEnd = now + wait
    -> Countdown screen

countdown:
    tick 1 Hz, render mm:ss + a progress ring
    // backing out before zero writes NOTHING — the gate failed, that is the point

onComplete:
    grant = TemporaryGrant(
        request:   request,
        startMs:   now,
        endMs:     now + config.grantDuration,   // or, for Unblock, the reel allowance
        cancelled: null)
    persist(grant)
    if (mode == increasing) batchCounter.increment()
    apply the existing session action (setPause / armReelSession)
    pop the gate

endEarly(grant):   grant.cancelledMs = now      // stops counting as active immediately
sweep(now):        drop grants where cancelledMs != null || endMs <= now
```

**Escalation curve.** B4's `hu.d` batch-counter body is bytecode-only — only its constructor
survived the decompile, so the growth function `f(n)` was **not recovered**. The batch-counter pref key and the counter's
existence are confirmed; the curve is not. Modelled
here as a monotone int with a reset window, and the curve exposed as configuration:

```
f(n) = n * escalationStep          // linear, escalationStep default 1 min
batchCounter resets when no grant has been taken for `batchResetWindow`
```

**Values B4 did not recover** — they lived on the source app's settings screen. These are Detoxo product
decisions, defaulted here and adjustable in settings:

| Knob | Default | Rationale |
|---|---|---|
| `baseWait` | **20 s** | Long enough to break the reflex, short enough not to feel punitive on a first use |
| `escalationStep` | **60 s** | Second attempt 80 s, third 140 s — the cost of repetition is felt by the third try |
| `batchResetWindow` | **2 h** | A genuinely new occasion starts from `baseWait` again |
| `grantDuration` | reuses the **existing** Pause window (2–10 min) and Unblock allowance (2–20 reels) | Do **not** invent a parallel duration model |
| `resistanceMode` | `standard` | Opt in to friction; do not surprise existing users |

The gate is **skippable by design when disabled** (`baseWait = 0` or the feature toggled off), so
this ships without changing anyone's behaviour until they turn it on.

### Data model

Hive, key `StoreKeys.waitingRoom`, one JSON document:

```jsonc
{
  "resistanceMode": "standard",       // stable name string
  "baseWaitMs": 20000,
  "escalationStepMs": 60000,
  "batchResetWindowMs": 7200000,
  "batchCount": 0,
  "batchLastGrantMs": 0,
  "grants": [                          // bounded: keep the last 20, prune on write
    { "kind": "PAUSE", "startMs": 0, "endMs": 0, "cancelledMs": null }
  ]
}
```

Enums persist as **stable name strings**, never ordinals — a reorder must not silently remap
saved state.

### Channel delta

**None of its own.** The grant applies through the commands that already exist:
`pushSettings {pauseUntil}` for Pause and `armReelSession {count}` for One Reel / Unblock.
The waiting room is friction *in front of* those calls, not a new enforcement path.

### Module layout

```
lib/features/limits/waiting_room/
├── domain/entities/{resistance_mode,unblock_request,temporary_grant,waiting_room_config}.dart
├── domain/repositories/waiting_room_repository.dart
├── data/repositories/waiting_room_repository_impl.dart
└── presentation/{waiting_room_cubit.dart, countdown_screen.dart}
```

Exported from the existing `lib/features/limits/limits.dart` barrel.
`computeWait(mode, base, step, batchCount)` is a **static `@visibleForTesting` pure method** on the
cubit — the pattern `StreakCubit.advance` already establishes in this repo.

### Reuse map

| Existing | Take |
|---|---|
| `CountdownCubit` (`lib/features/blocking/plans/presentation/`) | The 1 Hz tick and progress rendering — the countdown already exists; the waiting room is a second use of it, not a second implementation |
| `SessionPhase.cooldown` + `cooldownProgressPct` | Modelled and unused today (`startPause` hardcodes `cooldownDuration: Duration.zero`). **This is the waiting room.** Wire the existing model rather than adding a parallel one |
| `ContentRepository` emoji bands + `mindful_timer_quotes.json` (59 quotes) | DI-registered, built, and called by **no screen**. The countdown is the screen they were made for |
| `StreakCubit.advance` | Static pure method + `bloc_test` |

> Three modelled-but-unmounted pieces converge here. M2.1 is substantially *wiring what exists*,
> which is why its effort is M and not L.

---

## M2.2 — Emergency pass

### Algorithm & control flow

Constants from D4, verbatim: `VALIDITY = 1 h`, `COOLDOWN = 7 d`.

```
stateAt(history, now):
    if (history.isEmpty) return Available(canRedeem: entitlement.isEntitled())
    latest      = history.maxBy(redeemedAtMs)
    expiresAt   = latest.redeemedAtMs + VALIDITY
    cooldownEnd = latest.redeemedAtMs + COOLDOWN
    if (now <  expiresAt)   return Active(until: expiresAt)
    if (now >= cooldownEnd) return Available(canRedeem: entitlement.isEntitled())
    return Cooldown(remaining: cooldownEnd - now)

canRedeem(now) =
    entitlement.isEntitled()
    && (history.isEmpty || now >= history.last.redeemedAtMs + COOLDOWN)

redeem(now):
    if (!canRedeem(now)) return                 // re-guard; the button was already disabled
    ledger.append(Bypass(kind: EMERGENCY, atMs: now))   // the ONLY write
    prune to the newest 50
    push the lifted state to native

// `history` above is ledger.entries.where(kind == EMERGENCY) — M8 adds OVERRIDE
// entries to the same list, and each preset reads only its own kind.
```

Two properties worth preserving deliberately:

1. **Derive, don't store.** Only redemption timestamps persist. `expiresAt`, `cooldownEnd` and the
   `Active | Cooldown | Available` state are computed getters. There is no way for a stored
   `expiresAt` to disagree with its `redeemedAt`, because it does not exist.
2. **The state stream is `redemptions + a 1-minute ticker`**, so Active → Cooldown → Available and
   the countdown text re-emit with no user action and no push. The ticker runs only while the
   screen is mounted — it is a UI concern, not an engine one, and adds nothing to the hot path.

Countdown text takes `[days, hours % 24, minutes % 60]`; the history list renders `MM/dd`.

### The enforcement side

While a pass is active, blocking lifts. The lift is expressed the way Detoxo already expresses a
global lift — `pushSettings {pauseUntil: expiresAt}` — so **no native change is required at all**.
The engine's existing pause gate (checked at step 8 of the event loop, below the whole-app block
branch) does the work.

That placement is a real behaviour statement worth documenting on the screen: a whole-app block is
checked *above* the pause gate, so an emergency pass lifts reel blocking and web blocking but
**not** a whole-app block. Either accept and document that, or move the app-block branch below the
gate — a decision M3 has to make anyway, and this doc defers to it.

### Entitlement

One-method seam, default permissive:

```dart
abstract class EmergencyPassEntitlement { bool isEntitled(); }
class AlwaysEntitled implements EmergencyPassEntitlement { bool isEntitled() => true; }
```

Bound to `AlwaysEntitled` in `injector.dart`. If real billing ever lands, this is the one line that
changes, and it is exactly the **fail-open** shape E6 argues for: a failure in the entitlement
check must never deny a user their break-glass.

### Data model

Hive, key **`StoreKeys.bypassLedger`**:

```jsonc
{
  "config": { "overrideLimit": 2, "overridePeriod": "WEEK",
              "overrideMaxWindowMs": 3600000, "liftsUnlockedRulesToo": false },
  "entries": [                                 // newest first, max 50, prune on write
    { "kind": "EMERGENCY", "atMs": 1756742400000, "ruleId": null, "reason": null }
  ]
}
```

> **Build this as a ledger with a `kind` discriminator from day one**, even though M2.2 writes only
> `EMERGENCY` entries. [M8](10-M8-locked-rules-and-app-unblock.md) adds the `OVERRIDE` preset —
> rationed, reasoned, scoped to one locked rule — to **this same store**. Shipping an
> `emergencyPass`-only key and renaming it later is a persisted-key change, which is a one-way door
> and exactly the kind of contract churn [09](09-contracts-and-storage.md) exists to prevent.
> `config` is inert until M8 reads it.

Everything else is still derived: two columns in D4's drift table become one array here, and
`expiresAt` / `cooldownEnd` / the state are computed getters over it.

### Channel delta

**None.** Reuses `pushSettings {pauseUntil}`.

### Module layout

```
lib/features/limits/emergency_pass/
├── domain/entities/emergency_pass.dart          # EmergencyPassState + computed getters
├── domain/gateways/emergency_pass_entitlement.dart
├── domain/repositories/emergency_pass_repository.dart
├── data/repositories/emergency_pass_repository_impl.dart
└── presentation/{emergency_pass_cubit.dart, emergency_pass_screen.dart,
                  widgets/{hold_to_redeem_button,status_pill}.dart}
```

Hold-to-redeem needs **no dependency** — `GestureDetector` + `AnimationController`.

### Reuse map

| Existing | Take |
|---|---|
| `lib/core/design_system/components/buttons.dart` | The button base for hold-to-redeem |
| `PinConfig`'s lockout ladder | The "derive the current state from a timestamp + a constant" idiom, already proven in this repo |
| `monotonicNow` command | **Consider it.** EVO-015 anchored the PIN lockout to the monotonic clock precisely because a user can move the wall clock forward to clear a lockout. A 7-day cooldown is a strictly juicier target. See the ceiling below |
| `StreakCubit.advance` | Static pure `stateAt(history, now)` + `bloc_test` |

---

## Risks & ceilings

- **Clock tampering (M2.2).** `ponytail: cooldown is wall-clock; a user who moves the system clock
  forward 7 days clears it. Upgrade path = the monotonicNow + bootCount anchor EVO-015 already
  built for the PIN lockout.` A cooldown that trivially defeats itself is worse than no cooldown,
  because it advertises a commitment it does not keep. **Decide before shipping**, not after.
- **Escalation curve (M2.1).** `ponytail: linear f(n) = n * step; the original curve was
  bytecode-only and is not recovered. Tune from real usage.`
- **Interaction with the app-block branch.** Documented above; resolved in M3.
- **Do not stack friction.** If both the waiting room and a PIN scope guard the same action, the
  user meets two gates for one intention. Pick one per action and say which in the UI.
- **Accessibility.** Hold-to-redeem must have a keyboard/switch-accessible alternative; a
  press-and-hold gesture is not reachable for every user.

## Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] `pubspec.yaml` unchanged; no native change; no new channel method
- [ ] `computeWait` and `stateAt` are pure static methods with `bloc_test` coverage, including:
      standard vs increasing, batch reset after the window, backing out grants nothing,
      `now == expiresAt` (boundary), `now == cooldownEnd` (boundary), empty history
- [ ] State survives process death: kill the app mid-cooldown, relaunch, cooldown is intact
- [ ] Device sanity: Pause with the gate on shows the countdown; back-out leaves protection on;
      completion applies the existing pause; emergency pass lifts reel and web blocking for an
      hour then restores automatically
- [ ] `/docs-sync` — 05 (plans/pause), 07, 09, plus `info_docs/02` and an FAQ entry

## Target files

**New** — `lib/features/limits/waiting_room/**` · `lib/features/limits/emergency_pass/**` ·
`test/waiting_room_test.dart` · `test/emergency_pass_test.dart`

**Edited** — `lib/core/storage/local_store.dart` (+2 `StoreKeys`) · `lib/core/di/injector.dart` ·
`lib/features/limits/limits.dart` · `lib/core/navigation/{routes,app_router}.dart` ·
`lib/features/blocking/plans/presentation/` (route Pause/Unblock through the gate) ·
`lib/features/settings/presentation/settings_screen.dart` (resistance mode)
