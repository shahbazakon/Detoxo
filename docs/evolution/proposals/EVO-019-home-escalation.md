# EVO-019 — Escalate to HOME when BACK cannot leave a blocked page

- Status: proposed
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: web_blocker (native `accessibility/DetoxoAccessibilityService.kt`)
- Commit: fb23a68
- Date: 2026-08-28
- Effort: S

## Why
`handleBrowser` has exactly one remedy: `pressBackWithRateLimit()`
(`DetoxoAccessibilityService.kt:586`). When BACK does not leave the blocked host —
the first page of a fresh tab (the browser consumes the press or closes the tab
and lands on a new-tab page), a Chrome Custom Tab, or a `history.pushState` trap
(endemic on adult sites, now the largest category after EVO-017) — the host is
still on screen at the next content-changed event. The same-host debounce
(`sameAsLast && now - lastWebBlockTime <= BLOCK_DEBOUNCE_MS`, `:569-570`) expires
after 1200 ms and the whole routine re-fires: `recordWebBlock` prefs write,
`webBlocked` event, toast, vibration — every ~1.2 s, with no attempt counter and
no bound. Whole-app blocks already escalate correctly: `onAppBlocked` uses
`performGlobalAction(GLOBAL_ACTION_HOME)` (`:731`) because "BACK would just
navigate within it".

## Expected user impact
A blocked page that BACK can't escape is left in one firm move instead of a
toast/vibrate loop that reads as a malfunction. Strengthens the in-the-moment
intervention loop's credibility ("a firm, friendly nudge", product overview).

## Technical complexity
Native only, ~15 lines. Track consecutive blocks of the same host per browser
package (`lastUrlByPkg` already holds the host; add a small counter + timestamp).
On the second block of the same host within ~5 s, call
`performGlobalAction(GLOBAL_ACTION_HOME)` instead of BACK and reset the counter;
emit the event with `mode:"HOME"` so the stats/analytics keep the distinction.
No channel key or storage change; `mode` already exists in the payload.

## Performance impact
None on the hot path (a compare on the block path only, ≤ 1 per 1.2 s).

## Business value
Reliability of the website blocker — the intervention must not look broken.

## Rejected alternative
Navigate the browser to `about:blank` via an `ACTION_VIEW` intent: needs the
browser to honour it, foregrounds a new tab (visible flash), and leaves the
blocked tab in the tab switcher.

## Rollback
Revert the counter + HOME branch; BACK-only behaviour returns. No data involved.

## Implementation Plan
<!-- Fill this section ONLY once Status: approved. -->
