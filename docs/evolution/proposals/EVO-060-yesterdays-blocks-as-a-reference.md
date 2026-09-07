# EVO-060 — Yesterday's blocks as a neutral reference on the tile

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics`, `lib/features/blocking/shared` (snapshot), native `engine/ConfigStore.kt` + `engine/DateKeys.kt`, `design_system/components/cards.dart` (`StatCard.caption`)
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: S

## Why

The screen-time hero shows "Yesterday: 4h" (EVO-035's honest reference), but the block tile has
no context: `ConfigStore.recordBlock` zeroes the counter at rollover and forgets the previous
day, so the user cannot read 37 as a good or a bad day. The UX audit also counted three
different period affordances on one screen (the reel card's Today/All toggle, the two block
tiles, the hero's yesterday line).

## Expected user impact

"Blocked today 37 · Yesterday: 52" — a whole-day reference beside a running one, matching the
hero's pattern. No percentage and no streak (`01-product-overview.md`: "No shame charts").

## Technical complexity

- Native: two prefs keys (`block_yesterday`, `block_yesterday_date`) rotated inside
  `recordBlock` on the day change; `BlockTally.yesterday` derives the answer at read time;
  `DateKeys.dayBefore(now)` (Calendar arithmetic, DST-safe).
- Contract (named): the `blocked` event and the `blockStats` reply gain `yesterday: Int`.
- Dart: `ServiceSnapshot.blocksYesterday`; `StatCard` gains an optional `caption`; the
  today tile shows it once `blocksTotal > 0` (a fresh install has no yesterday to claim).

## Performance impact

One extra write per day, on the first block after midnight. Nothing per event.

## Business value

The honest-numbers story (`01-product-overview.md`, "Honest numbers"; EVO-035's precedent).
Modest, and it removes one of the three period affordances.

## Rejected alternative

A seven-day bar strip. Lost: it is the "chart you close and forget" the overview rejects, and
needs a day map natively.

## Rollback

Drop the caption and the snapshot field; the two prefs keys are ignored by an older build.

## Implementation Plan

### Current state

`recordBlock` resets `block_today` on a date mismatch and keeps nothing of the old day.
`StatCard` has `label / value / icon / unit / trend`.

### Target state

As in **Technical complexity**; `BlockTally.yesterday(storedDate, storedToday, rotatedDate,
rotatedCount, todayKey, yesterdayKey)` with the three cases pinned in `BlockTallyTest`.

### Repo conventions to follow

`webBlockStats` read-time rollover; `UsageQuery.startOfDay(now, zone)` for a testable zone.

### Steps

1. `DateKeys.dayBefore(now, zone)` + test.
2. `ConfigStore`: keys, rotation in `recordBlock`, `yesterday` in `blockStats`.
3. Payloads carry `yesterday`; `ServiceSnapshot.blocksYesterday`; `_readCounts`.
4. `StatCard.caption`; the today tile's caption.

### Boundaries

Never a percentage or a streak. If the cited code has drifted from the Commit stamp above,
STOP and report.

### Validation

- [x] `bash tool/dev.sh precommit` passes
- [x] baseline still empty
- [x] JVM tests added (`BlockTallyTest.yesterdayFollowsTheStoredDay`, `dayBefore…`)
- [x] Invariants grep clean
- [x] Production readiness: rotation survives process death and reboot; works offline; no
      new permission
- [x] `/docs-sync`: `12` §1, `18`, `09` updated
