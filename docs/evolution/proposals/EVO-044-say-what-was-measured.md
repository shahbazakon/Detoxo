# EVO-044 — Say what was measured, not what was assumed

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement)
- Feature: `android/app/src/main/res/values/strings.xml`
- Date: 2026-09-04
- Effort: XS

## Why

`nudge_body` read "Still scrolling. Good time to stop?" — an assertion about an activity the
engine never observed. `NudgeTracker.tick` takes a package and a clock and walks no nodes
(the doc is explicit that it adds nothing to `maxNodeTraversal 12000`). So the card fired at
users reading DMs, composing a post, or on a video call inside a `distracting`-behaviour app,
and told them they were scrolling.

## Expected user impact

Medium. A single confidently wrong sentence is disproportionately expensive for a product
whose pitch is honest numbers — and it arrives at the moment the user is deciding whether to
trust the app's judgment.

## Technical complexity

Trivial — one string.

## Performance impact

None.

## Business value

The wall's copy is derived from a reason the engine actually computed (`wall_reason_*`); this
brings the nudge to the same standard. The title already carries the one fact the engine has.

## Rejected alternative

Making the assertion true by observing scroll events on the nudge path. Rejected outright:
it would put node/scroll inspection on an advisory path that currently touches nothing, for
a cosmetic gain.

## Implementation plan

1. `nudge_body` → "Good time to put it down?" — asserts nothing.
2. A comment above the string recording *why* it asserts nothing, so it is not "improved"
   back into a claim later.
