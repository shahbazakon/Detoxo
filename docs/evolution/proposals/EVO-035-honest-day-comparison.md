# EVO-035 — Stop comparing a part-day against a whole one

- Status: done
- Tier: 2 (enhancement)
- Feature: analytics/insights
- Commit: 190042a (working tree; stamp the hash on commit)
- Date: 2026-09-04
- Effort: S

## Why
screenTimeDeltaPercent measured today's running total against yesterday's finished one, so at 08:00 it rendered '95% less than yesterday'. The cubit's own comment named this exact failure mode for the opposite case and guarded only that half.

## Expected user impact
The hero shows 'Yesterday: 4h' as a plain reference. The user compares; the app stops asserting a verdict it cannot support.

## Technical complexity
Dart only. screenTimeDeltaPercent now requires both days complete (so it is null on the live screen and available to a future history view); the view renders yesterdayScreenTime.

## Performance impact
None.

## Business value
The feature's entire pitch is honest numbers. A daily false triumph undermines it more than the metric was worth.

## Rejected alternative
Pro-rating yesterday by elapsed wall-clock — rejected: we store day totals only, so a 'pace' figure would be invented precision, exactly the over-claim removed from the footnote in the same pass.

## Rollback
Restore the percentage rendering. No stored state.

## Implementation Plan
Implemented in the 2026-09-04 evolution run; see `docs/code_docs/28-insights.md`
(and `25-block-screen.md` for EVO-034) for the shipped behaviour, and the tests
listed there for the pinned contract.
