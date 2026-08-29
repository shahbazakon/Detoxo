# EVO-034 — Show what the reach cost, on the wall

- Status: done
- Tier: 2 (enhancement)
- Feature: native overlay + engine/UsageQuery.kt
- Commit: 190042a (working tree; stamp the hash on commit)
- Date: 2026-09-04
- Effort: S

## Why
EVO-027 put 'Instagram opened 7 times today' on the wall. It says how often the reach happened and nothing about what it cost, while the usage layer already holds the answer.

## Expected user impact
At the moment of interception the user sees '1h 10m today in Instagram' under the opens count — an insight inside the intervention rather than in a chart the next morning.

## Technical complexity
Native. UsageQuery.timeTodayMs + formatHm (mirroring Dart), one extra queryAndAggregateUsageStats on the existing IO thread in the same pass as the opens query. WallView.extraStat became extraStats (List) so each line renders as its own block.

## Performance impact
One extra binder call per wall, on the IO executor, alongside a query already being made. Nothing on the accessibility hot path.

## Business value
The purest expression of the differentiator: awareness delivered in the moment, not the morning after.

## Rejected alternative
A second late-fill round trip — rejected: it would repaint the wall twice; both figures now come back in one pass.

## Rollback
Revert the overlay/renderer/UsageQuery changes and the wall_time_today string. No stored state, no wire change.

## Implementation Plan
Implemented in the 2026-09-04 evolution run; see `docs/code_docs/28-insights.md`
(and `25-block-screen.md` for EVO-034) for the shipped behaviour, and the tests
listed there for the pinned contract.
