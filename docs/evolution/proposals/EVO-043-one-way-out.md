# EVO-043 — Give the nudge card one way out

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement)
- Feature: `android/.../overlay/NudgeOverlay.kt`, `DetoxoAccessibilityService.kt`
- Date: 2026-09-04
- Effort: M

## Why

Detoxo's differentiator is in-the-moment *intervention* — the product overview's own
comparison table sells "steps in **while** you're scrolling" against "show you a report
after the time is gone". The soft nudge as shipped was the one Detoxo surface on the wrong
side of that line: it told the user they had been in Instagram fifteen minutes and offered
them nothing but "dismiss". Awareness delivered at exactly the right moment, then dropped.

## Expected user impact

High for the cost. The card arrives precisely when the user is deciding whether to keep
scrolling; making the exit one tap away converts the information into an action without
taking the decision away from them.

## Technical complexity

Medium. The window and teardown already exist; `BlockScreenOverlay.goHome` is the shared
launcher intent the wall uses. The real work was choosing the action.

## Performance impact

None. One more `TextView` in a card built ≤ `dailyCap × distinct apps` times a day.

## Business value

Closes the gap between what the nudge is and what the product promises. It also gives the
middle setting a reason to exist next to a hard block: "let me in, but help me leave".

## Rejected alternative

"Take a break" (start a Pause) and "Block it now" (escalate to the wall). Both rejected:
they make the *engine* act off the back of an advisory surface, which breaks the nudge's
load-bearing invariant ("the nudge never blocks") and would make the feature something a
user could be surprised by. `goHome` is the user leaving, on their own tap — the engine
still never presses BACK and never bounces anyone.

## Implementation plan

1. `NudgeOverlay.show` gains an `onLeave: () -> Unit = {}` parameter, threaded to `buildCard`.
2. A `Leave` `TextView` between the text block and the ✕: accent-on-tint pill, 48 dp floor,
   `isFocusable`, `R.string.nudge_leave`. On tap `hide()` then `onLeave()`.
3. The service passes `onLeave = { BlockScreenOverlay.goHome(this) }`.
