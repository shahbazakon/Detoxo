# Soft Nudge

Written from shipped source. Every intervention Detoxo had was binary: a feed is blocked or it is
not. That fits reels, which have no legitimate "a little bit", and fits badly everywhere else — a
user who wants to spend *less* time somewhere, not zero, had no way to say so except a hard block
they end up switching off. This is the middle setting: let the app open, and say something once
the user has been in it a while. Plan doc:
[`plan_docs/08-M7-soft-nudge.md`](../plan_docs/08-M7-soft-nudge.md) (shipped, with two deliberate
deviations — §8).

The load-bearing decision: **the nudge never blocks.** It never presses BACK, never bounces HOME,
never returns from `onAccessibilityEvent`, and never mutates block state. It reads a package name
off an event that has already been dispatched and, at most, raises a card that goes away by itself.
Everything sensor-shaped in the source material (activity recognition, accelerometer, light sensor,
the context-event log, the `ACTIVITY_RECOGNITION` permission) is dropped — see §8.

---

## 1. Layout

```
android/.../engine/NudgeTracker.kt            the dwell machine — Android-free, JVM-tested
android/.../overlay/NudgeOverlay.kt           the card: its own bottom-anchored window
android/app/src/test/kotlin/.../engine/NudgeTrackerTest.kt   24 scenarios

lib/features/blocking/shared/domain/nudge_sync.dart          the derived watch list + the push
lib/features/blocking/shared/domain/entities/app_settings.dart  three fields
lib/features/blocking/shared/presentation/settings_cubit.dart   three setters
lib/features/settings/presentation/settings_screen.dart         the toggle + the picker sheet
lib/features/catalog/domain/entities/catalog.dart               packagesWithBehavior
```

No feature directory of its own: three settings do not earn an entity, a repository, a cubit, a
screen, a route and a `StoreKeys` slot — see §8.

## 2. What the user gets

Open a distracting app and nothing happens. Stay in it and, at five minutes, a card slides up from
the bottom saying so, with one action on it: **Leave**. Tap Leave and you are home; tap the card or
its ✕, or ignore it for six seconds, and it goes. Stay longer and it returns at ten minutes, at
fifteen. Leave for a minute and the clock resets. Four cards per app per day and then it stops.

Nothing is *blocked* — the engine never presses BACK and never bounces anyone for a nudge. Leave is
the user's own tap, which is the point: the card would otherwise tell someone they had been
somewhere fifteen minutes and offer them nothing to do about it. Touches outside the card go
straight through to the feed underneath, so it can be ignored completely. It is off until switched
on, and the Settings row says so when the overlay grant is missing (§7).

## 3. The dwell machine

[`NudgeTracker`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NudgeTracker.kt)
is pure Kotlin with no Android imports — the [`ReelTracker`](03-detection-engine.md) template.
Its whole API:

```kotlin
fun tick(pkg: String?, nowMs: Long, dayKey: String): NudgeDecision   // None | Dismiss | Show
fun configure(enabled, packages, thresholdStepMs, dailyCap, idleTimeoutMs)   // in place
fun onDismissed()   // the card went away: re-arm
fun reset()         // forget the live session
```

Four rules carry the behaviour:

- **The watermark advances by exactly one step per crossing**, never to the elapsed total. One
  event that straddles two thresholds fires one card, and the next event picks up the second — a
  user is never handed four queued nudges at once.
- **The idle timeout is measured from the last event of that app, and applied whatever is
  foreground.** A minute with no event ends the stay; the next open starts from zero. Applying it
  on *both* branches, not only when the user leaves, is what stops a phone locked overnight inside
  Instagram from waking up to a "480 minutes" card.
- **`currentNudgePkg` is cleared whenever the card is not showing.** Without that clear, a
  dismissed nudge never returns.
- **`configure` reconfigures in place and never refills the day's budget.** This is not a detail.
  `pushSettings` reaches the engine on *every app resume* and after *every* settings write, so
  rebuilding the tracker on a config push — which is what the first cut did — silently handed the
  user a fresh daily allowance and a fresh dwell clock every time they opened Detoxo or changed
  their theme. Only a changed **step** drops the live session, because only the step changes what a
  watermark means; the tally survives everything short of process death.

The daily cap lives here too: a `pkg → count` map keyed to the `dayKey` the caller passes (the same
`DateKeys.today()` the content counter rolls on), cleared on rollover. It is bounded by
`distractingSet.size` — 41 packages in the shipped seed — not by session or day length.

A **backwards** wall clock (NTP correction, the user setting the date) ends the stay rather than
wedging it: the elapsed delta would go negative and suppress every nudge for that app until the
clock caught up.

## 4. Where it is driven from

One call in
[`DetoxoAccessibilityService.onAccessibilityEvent`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt),
beside the content counter's — **after** the privacy guard's `return` and **before**
`if (!masterOn) return`:

```kotlin
if (contentCounter.isEnabled) countContent(event, pkg)
if (nudge.enabled && nowMs - lastNudgeTickMs >= THROTTLE_MS) { … tickNudge(nowMs) }
if (!masterOn) return
```

That position is the whole contract. Below the privacy guard, so a protected app is as invisible to
the nudge as to everything else. Above the master switch and the pause gate, because the nudge is
advisory: the user asked to be told how long they have been somewhere, which is true whether or not
blocking is on — exactly the content counter's argument.

**No new ticker and no new thread.** It is driven by the events the service already receives.

Two details that are easy to get wrong:

- It runs on **every** accessibility event, not only `TYPE_WINDOW_STATE_CHANGED` — but on its own
  `THROTTLE_MS` stamp, not the block path's map (that map is keyed on the *event's* package, and the
  nudge is driven by the latched one). The idle timeout needs a heartbeat that is dense relative to
  `IDLE_TIMEOUT_MS`: window changes alone are minutes apart inside a feed and would read a user who
  is simply scrolling as one who left, while ~6.7 Hz still leaves a 400× margin.
- It is passed `nudgeForegroundPkg`, **not** the event's own package and **not** `foregroundPkg`.
  A background app's content-changed event carries its own package while the user is elsewhere, so
  identity must only move on a real window change; and `foregroundPkg` latches the *IME's* package
  when the keyboard opens. `nudgeForegroundPkg` is latched in the window-change branch, reusing the
  single `isImePackage(pkg)` resolve the counter already pays for — that call is a binder read and
  must never reach the per-event path.
- **The latch is `null` for a protected app, and that is load-bearing, not belt-and-braces.** The
  privacy guard keys on `foregroundPkg`, which the IME's own window clobbers — so once the keyboard
  opens inside a protected app the guard stops firing while a naive latch would still be pointing at
  the protected package, handing it to `tick`. The set pushed to the engine has the protected apps
  subtracted as well (§6), so the two would both have to be wrong.

It adds **nothing** to the tree walk and nothing to `maxNodeTraversal 12000`: no node is touched.

## 5. The card

[`NudgeOverlay`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/NudgeOverlay.kt)
is its own window, deliberately **not** the [block screen](25-block-screen.md):

| | Block screen | Nudge |
|---|---|---|
| Size | `MATCH_PARENT`, full screen | 88 % width, `WRAP_CONTENT` |
| Gravity | `TOP or START` | `BOTTOM or CENTER_HORIZONTAL`, 96 dp up |
| Touches | swallowed, plus two back-gesture edge strips | `FLAG_NOT_TOUCH_MODAL` — everything outside the card passes through |
| Lifetime | until the user acts or leaves | 6 s, then itself |

A wall's job is to interrupt; a nudge's job is the opposite — it must never take a tap the user
meant for the feed. Shared with the bubble and the wall: `overlayType()` from `OverlayWindows.kt`,
the `Settings.canDrawOverlays` guard with its `OVERLAY_RECHECK_MS` throttle and one-shot warning,
and the `removeView`-swallowing teardown. The card is a `LinearLayout` with a rounded
`GradientDrawable` — no custom `onDraw`; copy is in `res/values/strings.xml` as `nudge_title` /
`nudge_body` / `nudge_dismiss`.

The card carries one action, **Leave** (`goHome`), a ✕, and a whole-card tap that dismisses. All
three touch targets take the wall's 48 dp floor, and the card has a TalkBack label of its own.

**The two overlays never coexist**, in both directions. `tickNudge` short-circuits on
`BlockScreenOverlay.isShowing()`, and `raiseWall` calls `NudgeOverlay.hide()` — needed because the
nudge tick runs *earlier in the same event* than the block path, so without it a standing card
outlived the block and, being added later, sat above the wall taking taps. Screen-off and service
teardown (`tearDownOverlays`) take both windows down together.

Without the overlay grant `show` returns false, the service reports nothing, and the tracker is
re-armed — an advisory feature does not raise a permission prompt mid-scroll.

## 6. Which apps

`distractingSet` is
`Catalog.bundled.packagesWithBehavior(AppBehavior.distracting)` — derived from the shipped taxonomy
([26](26-catalog-and-usage-signal.md)), never curated. There is no nudge list to maintain and none
to drift: an app added to the seed is nudged the day it ships.

**Minus the protected apps** ([24](24-protected-apps.md)), subtracted natively in
`refreshNudgeConfig` from `ConfigStore.protectedPackages` — and `refreshProtectedPackages` re-runs
it, so protecting an app takes the nudge off it immediately rather than at the next unrelated push.
Protecting a distracting app is a supported, PIN-gated action, so the intersection is reachable and
this is the second of the two anchors described in §4.

Being in this set is **not** being blocked. It is the only place in the engine where a flat package
set means "time this", and `ConfigStore.nudgePackages` is commented to say so.

## 7. Persistence & channel

Dart owns the three settings on `AppSettings` (`nudgeEnabled` false, `nudgeThresholdMinutes` 5,
`nudgeDailyCap` 4) — persisted in the single `StoreKeys.settings` document ([09](09-persistence-data-model.md)),
absent keys reading as the defaults so a pre-M7 blob upgrades cleanly.

Both are clamped in `fromJson` and in the setters to the same range native coerces to, so a corrupt
blob cannot render "up to -5 per app a day" while the engine quietly enforces 1.

Native mirrors them in `detoxo_engine_prefs`: `nudge_enabled`, `nudge_packages` (a `StringSet`),
`nudge_step_ms` (clamped 1–60 min) and `nudge_daily_cap` (clamped 1–50).

**Session state is runtime-only and deliberately not persisted.** A session that survives a process
death is a session that nudges about an app the user closed an hour ago.

| Method | Args | Returns |
|---|---|---|
| `pushNudgeConfig` | `{enabled, packages, thresholdStepMs, dailyCap}` | `true`; each field independently a no-op when absent |

Pushed by `syncNudgeConfig` (reached through the `blocking.dart` barrel, the `limits.dart`
precedent) from the boot / resume `syncEngineBlocklists` fan-out and again by `SettingsCubit` after
any of the three setters. Native answers it with `refreshNudgeConfig()`, which reconfigures the
tracker **in place** — see §3 — subtracts the protected set, and hides any standing card when the
feature was switched off.

**The Settings row tells the truth about the grant.** `_NudgeTile` reads `AppPermission.overlay`
through `PermissionsCubit.effectivelyGranted` (the EVO-014 `lastKnownGranted` fallback, so a flaky
channel read never accuses a working setup) and, when the switch is on without the grant, tints the
icon and offers "Needs *Display over other apps*". Without it the toggle read ON while
`NudgeOverlay.show` returned false on every crossing and the service reported nothing — the same
shape `_SuppressionTile` (EVO-036) and `ContentCount.bubbleBlocked` (EVO-022) already solve, the
latter for this very grant.

New event `type` **`nudgeShown`** — `{package, elapsedMs, thresholdMs}`. Full contract in
[18](18-platform-channel-contracts.md). `NativeEventReporter` forwards **only the threshold band**
to Firebase as `nudge_shown` / `duration_min`; the package never leaves the device
([19](19-firebase-telemetry.md)).

## 8. Deviations from the plan doc

**Rendering.** The plan said the nudge would reuse M1's window and "add no window code". It cannot:
`BlockScreenOverlay` is a single-slot, full-screen, touch-swallowing modal with gesture defence —
the opposite shape. Bending it would have needed a second window slot, a bottom-gravity params
branch, a touch-swallow bypass and a renderer path, inside the load-bearing block modal. A separate
~150-line `NudgeOverlay` is the smaller and safer diff.

**Config surface.** The plan specified a `blocking/soft_nudge/` feature directory (entity,
repository, impl, cubit, settings screen, DI line, route, `StoreKeys` slot, barrel export). Three
scalars do not earn that; they went on `AppSettings`, reusing the shipped settings repository,
cubit, store key and screen.

**Sensors** were dropped in the plan itself, not here: the source material's live sensor→category
classifier had unrecovered thresholds, and inventing them to power a distinction ("you are in bed")
the product has no use for — behind a new runtime permission — is a bad trade. The dwell machine
needs no sensor; the foreground package is already known.

## 9. Ceilings

- `ponytail:` **event-driven only.** A genuinely event-silent minute — a full-screen video emitting
  nothing at all — reads as leaving, and the stay restarts. Deliberately the safe direction: the
  alternative is a card claiming eight hours after a night on the charger. Upgrade path is folding
  the tick into the Conscious accountant's 1 Hz timer when that is already running, which can tell
  a sleeping screen from a quiet one.
- `ponytail:` **per-visit, not per-day.** The threshold is elapsed time inside one visit to one app.
  Two four-minute visits never nudge. "Tell me after 30 minutes today" is the
  [daily limit](27-rules-engine.md), which already exists — the settings copy says so rather than
  building it twice.
- `ponytail:` **the session and the daily tally die with the process.** Deliberate for the session;
  the cost is that the cap resets with the service, which in practice outlives a day. A config push
  does *not* reset them — see §3.
- A crossing reached while a card is already up is consumed without a second card. Unreachable
  at the shipped 1-minute floor, which `ConfigStore` clamps to — ten times the card's 6 s life —
  so no test exercises it.

## 10. Tests

`NudgeTrackerTest.kt` — 24 scenarios, JUnit4, in the `tool/dev.sh precommit` gate. A `stay(from, to)`
helper replays the dense heartbeat production delivers, because the idle rule is written against it.

Covers: no nudge before the first threshold · exactly one at each crossing · one step per crossing
even when an event straddles two · idle beyond the timeout restarts the clock · a short detour does
not · an overnight gap never claims eight hours · switching distracting apps starts fresh · leaving
takes the card away, staying does not · dismiss-then-stay re-arms · a non-distracting app, a null
package and `enabled = false` never fire · the daily cap stops further nudges, is per app, and
clears on day rollover · `reset()` forgets the session.

Added after the post-ship audit: an unchanged config push keeps the day's tally *and* the live
session; a changed step restarts the stay; disabling clears it; a protected app is not in the watch
list; a backwards clock ends the stay instead of wedging it.

`test/nudge_config_test.dart` — the Dart half: the three fields' defaults, JSON round-trip, a
pre-M7 blob upgrading to off, independent `copyWith`; and that the watch list is exactly the
catalog's distracting packages and excludes everything else.

`test/plans_pause_curious_test.dart` — the three `SettingsCubit` setters, in the existing
`_FakeEngineRepo` harness: each persists **and** pushes the nudge config (the one thing
`_commitNudge` exists to do), out-of-range values are clamped at the boundary, and the pushed watch
list carries only distracting packages.

## Source files

```
android/app/src/main/kotlin/com/errorxperts/detoxo/engine/NudgeTracker.kt
android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/NudgeOverlay.kt
android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt
android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt
android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt
android/app/src/main/res/values/strings.xml
android/app/src/test/kotlin/com/errorxperts/detoxo/engine/NudgeTrackerTest.kt

lib/features/blocking/shared/domain/nudge_sync.dart
lib/features/blocking/shared/domain/entities/app_settings.dart
lib/features/blocking/shared/domain/repositories/blocking_repositories.dart
lib/features/blocking/shared/data/repositories/engine_repository_impl.dart
lib/features/blocking/shared/presentation/settings_cubit.dart
lib/features/settings/presentation/settings_screen.dart
lib/features/catalog/domain/entities/catalog.dart
lib/app/engine_sync.dart
lib/core/constants/channel_constants.dart
lib/core/platform_channels/engine_channel.dart
lib/core/services/firebase/analytics/analytics_events.dart
lib/core/services/firebase/analytics/analytics_service.dart
lib/core/services/firebase/analytics/native_event_reporter.dart
test/nudge_config_test.dart
```
