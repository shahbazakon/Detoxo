# EVO-054 — Treat an empty Conscious bank as a spent budget on the wall

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: native `overlay/WallPolicy.kt` + `accessibility/DetoxoAccessibilityService.kt`
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: XS

## Why
The block-screen-as-mode change gated every reel wall on `BlockingMode == BLOCK_SCREEN`,
including the Conscious drain-to-empty site (`DetoxoAccessibilityService.kt`, the 1 Hz
accountant's `bank <= 0L` branch). The product overview says Conscious "eases you back out"
when the bank hits zero, and the wall is the only surface that says *"Your Conscious time
bank is empty"* — on Press back that moment became a silent bounce.

## Expected user impact
A Conscious user in any block mode sees the bank-empty wall the instant the bank drains, and
on every reel block while it stays empty. Strengthens the earn-as-you-abstain loop the
differentiator table names.

## Technical complexity
Native only. `WallPolicy.forced(reason, plan, bankMs)` gains the third clause
`reason == PLAN && plan == "CURIOUS" && bankMs == 0`. No channel or storage change.

## Performance impact
None on the hot path: evaluated once per debounced block (1200 ms) and once per drain-to-empty,
from fields the service already holds.

## Business value
Directly serves the Conscious plan (`01-product-overview.md` § Blocking plans, "Why Detoxo is
different"). The wall is the intervention; a plan whose whole idea is the bank must show the
bank hitting zero.

## Rejected alternative
A separate `BlockReason.CONSCIOUS_EMPTY` on the wire. Lost: it would strip the plan chip
(`sanitised()` blanks `plan` for non-`PLAN` reasons) and need a Dart mirror; the bank field
already carries the fact.

## Rollback
Delete the third clause in `WallPolicy.forced`. No persisted state.

## Implementation Plan

### Current state
`WallPolicy.forced(reason)` = `reason == DAILY_LIMIT` only; the drain site was wrapped in
`takeIf { WallPolicy.reelWall(store.defaultBlockMode, "PRESS_BACK", null) }`.

### Target state
`WallPolicy.forced(reason, plan, bankMs)` true for a `PLAN` block with `plan == CURIOUS` and
`bankMs == 0L`; `bypassesSwitch` inherits it. The drain site raises unconditionally (it is forced
by construction) with a comment naming the policy.

### Repo conventions to follow
Pure object + JVM test, `overlay/WallPolicyTest.kt`. Wire token `CURIOUS` verbatim
(`CommandHandler.PLAN_CONSCIOUS`); the UI label stays "Conscious".

### Steps
1. Extend `WallPolicy.forced`; add the payload overload.
2. Drop the gate at the drain site; keep `raiseWall`.
3. Pin `forced(PLAN, CURIOUS, 0) == true`, `forced(PLAN, CURIOUS, 30_000) == false`,
   `forced(PLAN, BLOCK_ALL, 0) == false` in `WallPolicyTest`.
4. Docs: `25-block-screen.md` §3 drain row, `03-detection-engine.md` wall rule.

### Boundaries
Do not touch the accountant's earn/drain arithmetic or `CONSCIOUS_MAX_STEP_MS`. If the cited
code has drifted from commit 185c7f7, STOP and report.

### Validation
- [x] `flutter analyze` clean, `flutter test` green, `bash tool/check_boundaries.sh` clean
- [x] Native JVM tests green (`WallPolicyTest` 4/4)
- [x] Invariants grep clean
- [x] Production readiness: no new state; overlay-revoked path falls back (toast at the reel site)
- [ ] Device sanity: Conscious, Press back mode, drain the bank mid-reel → wall with "Your Conscious time bank is empty"
- [x] `/docs-sync` run
