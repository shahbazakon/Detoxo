# EVO-033 — Set a daily limit straight from a top app

- Status: done
- Tier: 2 (enhancement)
- Feature: analytics/insights + limits/rules
- Commit: 190042a (working tree; stamp the hash on commit)
- Date: 2026-09-04
- Effort: S

## Why
Insights, as shipped, is the chart docs/info_docs/01-product-overview.md argues against — 'Most screen-time tools only tell you about it the next morning, in a chart you close and forget.' It was the one screen that worked against the differentiator.

## Expected user impact
Seeing '1h 10m' against an app is the moment a limit gets set. The row now opens the rule editor pre-filled for that app instead of leaving the user to find Rules and rebuild the thought.

## Technical complexity
Dart only. _AppRow pushes Routes.ruleEditor with RuleEditorArgs(kind: timeLimit, rule: prefilled). Required moving RuleEditorArgs from rules/presentation/ to rules/domain/ so analytics can reach it without a boundary violation.

## Performance impact
None — a tap handler.

## Business value
Turns the weakest screen into a funnel for M3, the strongest shipped feature. Cites the product overview's 'in the moment' positioning.

## Rejected alternative
Silently creating the rule on tap — rejected for the EVO-031 reason: the first thing anyone does with a suggested limit is disagree with the number.

## Rollback
Revert the InkWell and the RuleEditorArgs move. No stored state is created.

## Implementation Plan
Implemented in the 2026-09-04 evolution run; see `docs/code_docs/28-insights.md`
(and `25-block-screen.md` for EVO-034) for the shipped behaviour, and the tests
listed there for the pinned contract.
