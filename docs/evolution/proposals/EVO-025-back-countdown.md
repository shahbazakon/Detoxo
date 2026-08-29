# EVO-025 — Count down before "Back to {app}" unlocks on the block screen

- Status: done (implemented 2026-09-03 in the working tree on top of 190042a; stamp the commit hash here when it lands)
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/blocking/block_screen` + native `overlay/BlockScreenOverlay.kt`, `overlay/BlockScreenRenderer.kt`
- Commit: 190042a (working tree carries the uncommitted M0/M1 delta this builds on)
- Date: 2026-09-03
- Effort: S

## Why
The wall's ghost exit is enabled the instant the wall appears, so the reflex tap defeats the
intervention before it is read:

`android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenRenderer.kt:260-267`
```kotlin
        if (p.referenceType != BlockScreenPayload.TYPE_APP) {
            // Detoxo blocks reels, not apps: the way back into the app's other
            // screens (DMs, the previous tab) is a first-class exit.
            val label = p.appLabel.ifBlank { p.displayName }.ifBlank { res.getString(R.string.wall_this_app) }
            add(button(context, res.getString(R.string.wall_back_to, label), Style.GHOST, palette, accent) {
                onAction(ACTION_DISMISS)
            })
        }
```

## Expected user impact
"Back to Instagram" reads "Back to Instagram · 5" and is disabled for five seconds, ticking
down, then unlocks. "Go home" and "Open Detoxo" stay instant, so the wall never traps. The
delay is a style field the user can switch off in the block-screen editor ("Wait before going
back"). This is the in-the-moment loop's core move: the block is *felt* for five seconds.

## Technical complexity
Native: the renderer tags the ghost button; the overlay (which already owns the window lifecycle
and the main-looper handler) runs a 1 Hz countdown on that button and cancels it on detach.
Dart: one `int backDelaySec` field (default 5, 0 = off) inside the existing `block_screen_style`
JSON blob — not a new `StoreKeys` constant, not a new channel key; `BlockScreenStyle`,
`BlockScreenStyleCubit.setBackDelay`, one toggle in the editor, and the preview mirror shows the
locked label. One new string resource `wall_countdown` (`"%1$s · %2$d"`).

## Performance impact
At most five `postDelayed` ticks per wall, on the main looper, cancelled on detach. Nothing on
the accessibility hot path.

## Business value
`docs/info_docs/01-product-overview.md` — "a firm, friendly nudge exactly when you need it" and
the differentiator row "Easy to ignore or turn off → Optional PIN lock…": a wall that cannot be
reflex-dismissed is the nudge actually landing.

## Rejected alternative
Hold-to-confirm on the back button: less discoverable, and hostile to Switch Access / TalkBack
(a long-press is not a standard accessibility action on a Button).

## Rollback
Delete the field on both sides; a persisted JSON with the extra key still parses (`optInt`).
No storage migration, no manifest change.

## Implementation Plan

### Current state
- `BlockScreenRenderer.buildActions` (above) builds the ghost button with no handle.
- `BlockScreenOverlay.show()` (`overlay/BlockScreenOverlay.kt:88-161`) adds the view and calls
  `applyGestureDefence`; `detach()` (`:270-290`) removes the windows and clears state.
- `BlockScreenStyleSpec` (`BlockScreenRenderer.kt:111-135`) has `enabled, theme, background,
  showCount, accentByUsage`.
- Dart `BlockScreenStyle` (`lib/features/blocking/block_screen/domain/entities/block_screen_style.dart`)
  mirrors those five fields; `BlockScreenCopy.from` (`block_screen_copy.dart:72-81`) emits
  `BlockScreenButton('Back to $backTo', 'DISMISS', ghost: true)`.

### Target state
- `strings.xml`: `<string name="wall_countdown">%1$s · %2$d</string>`.
- `BlockScreenRenderer.TAG_BACK = "back"`; the ghost button gets `tag = TAG_BACK`.
- `BlockScreenStyleSpec.backDelaySec: Int = 5` parsed with `optInt("backDelaySec", 5)`.
- `BlockScreenOverlay`: `backButton`, `backLabel`, `countdownLeft`, a `countdownTick` Runnable;
  `armBackCountdown(root, spec.backDelaySec)` after a successful add; `renderBack()` sets
  `isEnabled`, `alpha` (0.55 locked / 1), `text` and `contentDescription`; `detach()` removes the
  callback and clears the fields.
- Dart `BlockScreenStyle.backDelaySec` (default 5) in `fromWire`/`toWire`/`copyWith`/`props`;
  `BlockScreenStyleCubit.setBackDelay({required bool on})` → 5 / 0; `BlockScreenButton.locked`;
  `BlockScreenCopy` ghost label `'Back to X · 5'` + `locked: true` when `backDelaySec > 0`;
  `BlockScreenPreview._Button` draws a locked button at 55 % opacity; editor gains a
  `SectionHeader('Friction')` + `AppToggleTile` "Wait before going back".

### Repo conventions to follow
`CounterAppearanceCubit` setter shape; `AppToggleTile` from `design_system/components`;
copy mirrored in `BlockScreenCopy` (MIRROR CONTRACT comment); pure logic tested — Dart
`block_screen_test.dart`, JVM `BlockScreenGeometryTest.kt` defaults test.

### Steps
1. Add `wall_countdown` to `res/values/strings.xml`.
2. Renderer: `TAG_BACK`, tag the ghost button; `backDelaySec` on the spec.
3. Overlay: countdown state + `armBackCountdown` + `renderBack` + cleanup in `detach`.
4. Dart style field, cubit setter, copy/preview mirror, editor toggle.
5. Tests: style round-trip with `backDelaySec`, copy label locked/unlocked, JVM default = 5.
6. Docs: `25-block-screen.md` §2/§5/§6, `18-platform-channel-contracts.md` style fields,
   `info_docs/02` §9, `info_docs/04` FAQ.

### Boundaries
Do not touch the trigger sites, the hide rules, `ContentCounterBubble`, or the widget renderer.
If the code at the cited lines has drifted from the Commit stamp above, STOP and report.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS" intact in wire/code, "Conscious" in UI
- [ ] Production readiness: style survives process death + reboot (`detoxo_engine_prefs`) · no grant needed · offline · no manifest change · countdown cancelled on detach
- [ ] Native touched → device sanity: the ghost button ticks 5→0 then unlocks; "Go home" instant throughout; toggle off → instant back
- [ ] `/docs-sync` run; mapped docs updated
