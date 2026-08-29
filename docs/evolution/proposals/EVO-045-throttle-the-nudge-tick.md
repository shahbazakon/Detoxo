# EVO-045 — Throttle the nudge tick

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement — touches a named engine budget)
- Feature: `android/.../accessibility/DetoxoAccessibilityService.kt`
- Date: 2026-09-04
- Effort: S

## Why

`tickNudge` ran on every accessibility event, 88 lines above the block path's
`THROTTLE_MS = 150` gate. The correctness argument in the doc — that the heartbeat must be
dense or `IDLE_TIMEOUT_MS` misreads a scrolling user as a departed one — justifies ticking on
content/scroll events rather than window changes alone. It does not justify ticking
*unthrottled*: 60 000 ms against 150 ms is a **400× margin**, so a throttled tick still
delivers ~400 ticks inside every idle window with identical watermark behaviour.

Measured cost of the difference: at a realistic 10–20 events/s during a fling, the tracker
was doing ~3.5 MB/h of young-gen garbage inside watched apps.

## Expected user impact

None visible. Battery only.

## Technical complexity

Low-medium. The existing throttle *map* could not be reused — it is keyed on the event's
package while the nudge is driven by the latched foreground package — so the nudge needs its
own stamp. The constant is shared, not changed.

## Performance impact

The point of the change: ~3× fewer ticks at scroll rates, and the same reduction in the
per-event allocation.

## Business value

Battery drain is a top uninstall driver for always-on accessibility apps, and the nudge is
the first thing Detoxo added to that path that was not free.

## Rejected alternative

Reusing `lastEventByPackage`. Rejected: it is keyed on a different package than the nudge
reads, so sharing it would couple the advisory path to the block path's throttle semantics
and make both harder to reason about.

## Implementation plan

1. `lastNudgeTickMs` field on the service.
2. Gate the call: `if (nudge.enabled && nowMs - lastNudgeTickMs >= THROTTLE_MS)`.
3. `THROTTLE_MS` itself is unchanged — the budget is respected, not retuned.
