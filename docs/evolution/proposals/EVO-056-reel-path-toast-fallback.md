# EVO-056 — Name the block when a wanted reel wall cannot show

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: native `accessibility/DetoxoAccessibilityService.kt` (`onDetected`)
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: XS

## Why
`onAppBlocked` and `onWebBlocked` keep the legacy toast when `raiseWall` returns false; the reel
site discarded the result (at HEAD too). With the wall now a user-selected mode, a Block screen
user whose overlay grant is revoked is bounced in silence — the one thing the intervention
surface must never be.

## Expected user impact
With the grant missing, the reel block shows *"Instagram Reels is blocked by Detoxo"* instead
of nothing. Only when a wall was wanted (Block screen mode or a forced block); Press back
users see no new toast.

## Technical complexity
Native only: `val shown = wanted && raiseWall(...)`, `if (wanted && !shown) Toast(toast_blocked,
payload.displayName)`. Reuses the existing string.

## Performance impact
One toast per debounced block in the failure case only.

## Business value
"Steps in while you're scrolling" — the block must be legible to be an intervention
(`01-product-overview.md` § Why Detoxo is different).

## Rejected alternative
A persistent notification "Block screen needs a permission". Lost: notification noise for a
state the Settings row already renders truthfully.

## Rollback
Delete the `if (wanted && !shown)` block.

## Implementation Plan

### Current state
`if (WallPolicy.reelWall(...)) { raiseWall(...) }` — result discarded.

### Target state
See Technical complexity. `shown` also feeds the `blocked` event (EVO-057).

### Repo conventions to follow
The `onWebBlocked` site's `if (!shown) Toast.makeText(...)` shape.

### Steps
1. Capture `shown`; toast on `wanted && !shown`. 2. Docs: 25 §1 contract, §3 reel row.

### Boundaries
No toast on the `NONE` or non-wanted paths. If the cited code has drifted from commit 185c7f7,
STOP and report.

### Validation
- [x] analyze / test / boundaries clean; native JVM tests green
- [ ] Device sanity: Block screen mode, revoke "Display over other apps", open Reels → toast + back press, no crash
- [x] `/docs-sync` run
