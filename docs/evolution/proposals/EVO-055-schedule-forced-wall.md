# EVO-055 — Force the wall for schedule blocks, like daily limits

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: native `overlay/WallPolicy.kt`
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: XS

## Why
EVO-028 built the "Blocked by a schedule · Unlocks at 5:30 PM" wall copy so a rule block names
when it lifts. With the wall gated on `BLOCK_SCREEN` mode, a schedule block on Press back shows
nothing — the investment of EVO-028 and EVO-030 (strict rules) became invisible in the default
mode, while the sibling `DAILY_LIMIT` reason was already forced.

## Expected user impact
Every schedule block shows the wall with its unlock time, in every block mode and with the
Appearance switch off. A schedule is a commitment the user set in advance, the same class as a
daily limit.

## Technical complexity
Native only: `WallPolicy.forced` adds `reason == SCHEDULE`. `bypassesSwitch` inherits it.

## Performance impact
None: one string comparison per debounced block.

## Business value
"Optional PIN lock and uninstall protection keep future-you honest"
(`01-product-overview.md`): rules are the commitment device, and the wall is how they speak.

## Rejected alternative
Leave schedules mode-gated and add a "Show the wall for rules" toggle under Appearance. Lost:
a fourth switch for one concept, and the user's stated spec already treats limits as forced.

## Rollback
Remove the `SCHEDULE` clause. No persisted state.

## Implementation Plan

### Current state
`WallPolicy.forced(reason) = reason == REASON_DAILY_LIMIT`.

### Target state
`forced(...)` also true for `REASON_SCHEDULE`. App-lock and website walls with a schedule reason
(package rules, host rules) bypass the Appearance switch the same way daily-limit ones do.

### Repo conventions to follow
`overlay/WallPolicyTest.kt`; `REASON_*` constants on `BlockScreenPayload`.

### Steps
1. Add the clause. 2. Pin `forced(SCHEDULE, …) == true` in the test. 3. Docs: 03, 25, 27 §wall.

### Boundaries
No change to `RuleEngine` or the snapshot contract. If the cited code has drifted from commit
185c7f7, STOP and report.

### Validation
- [x] analyze / test / boundaries clean; native JVM tests green
- [x] Invariants grep clean
- [ ] Device sanity: a schedule rule on Instagram, Press back mode, Appearance switch off → wall reads "Blocked by a schedule · Unlocks at …"
- [x] `/docs-sync` run
