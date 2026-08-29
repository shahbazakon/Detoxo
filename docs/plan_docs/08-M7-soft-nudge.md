# M7 — Soft nudge (dwell-based, sensors dropped)

- Status: **shipped** — engineering doc [`code_docs/30-soft-nudge.md`](../code_docs/30-soft-nudge.md); on branch `sensitive_protection` (commit pending at the time of writing). **Shipped with two deliberate deviations — see the box below; the plan text under it is the original and is kept for the record.**
- Source: [B5 Autofocus](../suggestion_docs/flutter-migration/B-blocking/B5-autofocus-context-blocking.md), dwell state machine only
- Feature areas: native `engine/NudgeTracker.kt`, `lib/features/blocking/soft_nudge/`
- Effort: **S** (one pure Kotlin state machine, rendered through M1's window)
- Blocked by: M0.1, M1 · Blocks: nothing


> ## ⚠ How this shipped, vs. what is planned below
>
> **Rendering — a separate window, not an M1 variant.** The plan's claim that the nudge "adds no
> window code" does not survive contact with the shipped `BlockScreenOverlay`: it is a single-slot,
> **full-screen, touch-swallowing** modal with two back-gesture edge strips. A nudge card is the
> opposite shape in every one of those dimensions. Bending it would have meant a second window
> slot (or a nudge would clobber a live wall), a bottom-gravity params branch, a bypass for the
> touch-swallow listener and the gesture defence, and a new renderer path — all inside the
> load-bearing block modal. `overlay/NudgeOverlay.kt` (~150 lines, reusing `overlayType()` and the
> counter bubble's permission/teardown patterns) is the smaller and far safer diff. The suppression
> the plan asked for is one line: `if (BlockScreenOverlay.isShowing())`.
>
> **Config — three fields on `AppSettings`, not a feature directory.** The `blocking/soft_nudge/`
> tree below (entity, repository, impl, cubit, settings screen, `StoreKeys` slot, DI line, route,
> barrel export, ~7 files) is not what three scalars earn. They live on the existing `AppSettings`
> and reuse the shipped `SettingsRepository`, `SettingsCubit`, store key and Settings screen.
> **One wire correction.** `nudgeShown` shipped exactly as specified, but `pushNudgeConfig`'s
> fourth argument is **`dailyCap`, not the `idleTimeoutMs`** named in the table below: the idle
> timeout stayed a native constant because it is not user-facing, while a per-app daily cap was
> needed to stop the card becoming wallpaper. Native therefore mirrors four prefs keys
> (`nudge_enabled`, `nudge_packages`, `nudge_step_ms`, `nudge_daily_cap`), not the two below.
> [09](09-contracts-and-storage.md) carries the shipped contract.
>
> **One correction to the text below:** the target path `android/app/src/test/NudgeTrackerTest.kt`
> is wrong — the convention is the mirrored package dir,
> `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/NudgeTrackerTest.kt`. And the two
> statements about the call site conflict ("inside the WINDOW_STATE_CHANGED branch" vs "after the
> privacy guard, before the master switch" — the guard returns *below* that branch). It ships at
> the second one, beside the content counter, and is driven from **every** event rather than only
> window changes: the idle timeout needs a dense heartbeat, and window changes alone are far too
> sparse inside a feed. The identity of a stay still moves only on a real window change.
>
> **One rule is stricter than the sketch below.** The idle timeout is applied on *both* branches,
> not only when the user leaves. Without that, a phone locked overnight inside Instagram wakes to
> a card claiming 480 minutes. The cost is that a genuinely event-silent minute reads as leaving —
> the safe direction, and recorded as a ceiling in the engineering doc.


The lowest-effort milestone and the last one, because it is the only capability here that is
genuinely optional to the product.

## Why now

Detoxo's interventions are binary: a feed is either blocked or it is not. That fits reels, which
have no legitimate "a little bit" — but it fits badly everywhere else. A user who wants to spend
*less* time on a distracting app, not zero, has no expression for that today except a hard block
they will end up disabling.

A nudge is the middle setting the plan set otherwise lacks: let the app open, and say something
after the user has been there a while.

## What the user gets

Open a distracting app and nothing happens. Stay in it and, at five minutes, a dismissible card
slides in with the elapsed time. Stay longer and it comes back at ten, at fifteen. Leave for a
minute and the clock resets. No blocking, no back-press — just the thing the user asked to be
told.

## Source: what is taken, what is dropped

**Taken** — the `tick(pkg)` state machine from `yq.b.b`, which B5 reports as verified line by line,
and its two constants.

**Dropped** — everything sensor-shaped, which is most of the document: GMS activity recognition,
the accelerometer, the light sensor, the context-event log with its 14-day retention, the windowed
context aggregation, and the `ACTIVITY_RECOGNITION` permission.

That is not a scoping shortcut, it is what the source material supports. B5 flags three separate
bytecode-only gaps, and the one that matters is `ho.b.b` — the live sensor→category classifier,
which decides STILL → sitting / standing / in-bed from tilt and light. **Its thresholds were not
recovered.** Porting it means inventing thresholds, then calibrating them across device classes,
to power a distinction ("you are in bed") the product has no use for. Adding a runtime permission
for that is a bad trade.

The dwell machine, by contrast, needs no sensor at all: Detoxo already knows the foreground
package on every `WINDOW_STATE_CHANGED`.

## Algorithm & control flow

Constants verbatim from `xj.d`: `THRESHOLD_STEP = 5 min`, `IDLE_TIMEOUT = 1 min`.

```kotlin
// engine/NudgeTracker.kt — Android-free, JVM-tested
data class Session(
    val pkg: String,
    val startedAtMs: Long,
    val lastTickMs: Long,
    val lastFiredThresholdMs: Long,        // the WATERMARK
)

fun tick(pkg: String?, nowMs: Long): NudgeDecision {
    if (!enabled) return None

    val distracting = if (pkg != null && pkg in distractingSet) pkg else null
    var fired = false

    if (distracting != null) {
        val s = session
        session = if (s == null || s.pkg != distracting) {
            // new app -> fresh session, watermark at zero
            Session(distracting, nowMs, nowMs, 0L)
        } else {
            val elapsed = nowMs - s.startedAtMs
            val next    = s.lastFiredThresholdMs + THRESHOLD_STEP
            if (elapsed >= next) {
                fired = true
                s.copy(lastTickMs = nowMs, lastFiredThresholdMs = next)   // advance ONE step
            } else {
                s.copy(lastTickMs = nowMs)
            }
        }
    } else {
        val s = session
        if (s != null && nowMs - s.lastTickMs > IDLE_TIMEOUT) session = null
    }

    if (!fired) {
        return if (overlayShowing) Dismiss else None      // leaving/quiet -> take the card away
    }
    if (currentNudgePkg == distracting) return None       // already nudging this app
    currentNudgePkg = distracting
    return Show(distracting!!, elapsedOf(session!!, nowMs))
}
```

Three details that are the whole state machine:

- **The watermark advances by exactly one step per crossing**, never jumping to the elapsed total.
  A user who leaves the phone on a feed for 22 minutes and comes back gets one nudge on their next
  event, not four queued ones.
- **`IDLE_TIMEOUT` is measured from `lastTickMs`, not from the session start.** A minute with no
  events in the distracting app — screen off, app switch, a call — ends the session. The next open
  starts from zero.
- **`currentNudgePkg` is cleared whenever the overlay is not showing**, which re-arms the machine
  after the user dismisses the card without leaving the app. Without that clear, a dismissed nudge
  never returns.

B5 flags the coupling between the watermark and the re-nudge gate as inferred (the show-overlay
coroutine was a non-decompiled suspend lambda). The behaviour above is the reconstruction B5
recommends; both constants stay configurable so it can be tuned from real use rather than argued
about in advance.

### Where it is driven from

`tick(pkg, now)` is called from the **existing** `WINDOW_STATE_CHANGED` branch of
`onAccessibilityEvent`, after the privacy guard and before the master switch — the nudge is
advisory and must run even when blocking is off, the same way the content counter does.

**No new ticker.** The machine is event-driven; a session that goes completely quiet simply does
not advance until the next event, which is correct: no events means no interaction to nudge about.

`ponytail: purely event-driven, so a silent 20-minute watch fires its nudge only on the next
event. Upgrade path = fold into the Conscious accountant's 1 Hz tick when that is already running.`

### Rendering

Through **M1's window**, with a `nudge` variant: bottom-anchored, auto-dismissing after ~6 s,
touch-passthrough outside the card so the user can keep scrolling. It adds **no window code** —
that is why M7 is sequenced after M1 and is an S.

The `distractingSet` is `catalog.packagesWithBehavior(distracting)` from M0.1, pushed alongside the
other flat sets. No new taxonomy, no second list to maintain.

## Data model

Hive, key reuses `StoreKeys.suppressedApps`'s neighbour pattern — one small settings document:

```jsonc
{ "enabled": false, "thresholdStepMs": 300000, "idleTimeoutMs": 60000 }
```

Session state is **runtime-only and deliberately not persisted**. A session that survives a process
death is a session that fires a nudge for an app the user closed an hour ago.

Native `detoxo_engine_prefs` gains `nudge_enabled` and `nudge_packages` (a `StringSet`).

## Channel delta

| Method | Args | Returns |
|---|---|---|
| `pushNudgeConfig` | `{enabled: Bool, packages: List<String>, thresholdStepMs: Long, idleTimeoutMs: Long}` | `true`; no-op on malformed |

New event `type`: **`nudgeShown`** — `{package, elapsedMs, thresholdMs}`, for the local analytics
feed so the user can see the nudges in their own activity history.

## Module layout

```
android/.../engine/NudgeTracker.kt          # Android-free; JVM-tested
android/app/src/test/NudgeTrackerTest.kt

lib/features/blocking/soft_nudge/
├── domain/entities/nudge_config.dart
├── domain/repositories/nudge_repository.dart
├── data/repositories/nudge_repository_impl.dart
└── presentation/{nudge_cubit.dart, nudge_settings_screen.dart}
```

Exported from `lib/features/blocking/blocking.dart`.

## Reuse map

| Existing | Take |
|---|---|
| [`engine/ReelTracker.kt`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ReelTracker.kt) | The exact template: an Android-free Kotlin state machine with its ceilings documented in the KDoc and a JVM test in the precommit gate (EVO-023). `NudgeTracker` is its sibling and should read like it |
| `ReelTrackerTest.kt` (23 scenarios) | The scenario-table test style |
| M1's `BlockScreenOverlay` / `BlockScreenRenderer` | The window and the renderer; add a variant, not a second overlay |
| `pushProtectedApps` / `pushAppBlocklist` | The flat-set push contract |
| `ContentCounter`'s `onForegroundChanged` | The same call site and the same IME-package skip |
| M0.1 `Catalog` | `packagesWithBehavior(distracting)` — the set, derived not curated |

## Risks & ceilings

- `ponytail: event-driven only; a silent watch nudges late.` (recorded above)
- `ponytail: threshold is wall-clock elapsed within one app, not cumulative daily use. Two 4-minute
  visits never nudge. Upgrade path = a daily accumulator, which is really M3's time limit — use
  that instead if that is what the user wants.` This is worth stating plainly in the settings copy,
  because "nudge me every 5 minutes" and "nudge me after 30 minutes today" are different features
  and the second one already exists.
- **Nudge fatigue.** A card every 5 minutes forever is ignorable by the third one. Cap the nudges
  per app per day (start at 4) and make the cap a setting.
- **Do not let the nudge fire while a hard block is active.** Two interventions for one moment is
  worse than either. Suppress the nudge whenever the wall is showing.
- Make sure the counting pass and the nudge tick do not both walk the tree — the nudge needs only
  the package name from an event that has already been dispatched, and it must add **nothing**
  to `MAX_NODES 12000`.

## Validation

- [ ] `bash tool/dev.sh precommit` passes, `NudgeTrackerTest.kt` included
- [ ] `NudgeTrackerTest` covers: no nudge before the first threshold; exactly one at each crossing;
      a 22-minute session fires once per event, not four times; idle for `IDLE_TIMEOUT` resets;
      app switch resets; dismiss-then-stay re-arms at the next threshold; a non-distracting app
      never fires; `enabled: false` is a hard no-op
- [ ] Disabled by default; with it off, hot-path behaviour is byte-identical to today
- [ ] The nudge never appears while the M1 wall is showing
- [ ] No new permission; `pubspec.yaml` unchanged
- [ ] Device sanity: open a distracting app, wait 5 min → card appears; dismiss → keep scrolling →
      card returns at 10 min; leave for a minute and return → clock restarts
- [ ] `/docs-sync` — 03, 04, 18 + `info_docs/02`

## Target files

**New** — `android/.../engine/NudgeTracker.kt` · `android/app/src/test/NudgeTrackerTest.kt` ·
`lib/features/blocking/soft_nudge/**` · `test/nudge_config_test.dart`

**Edited** — `android/.../accessibility/DetoxoAccessibilityService.kt` (one call in the existing
`WINDOW_STATE_CHANGED` branch) · `android/.../overlay/BlockScreenRenderer.kt` (nudge variant) ·
`android/.../channels/CommandHandler.kt` · `android/.../engine/ConfigStore.kt` ·
`lib/core/constants/channel_constants.dart` · `lib/features/blocking/blocking.dart` ·
`lib/features/settings/presentation/settings_screen.dart`
