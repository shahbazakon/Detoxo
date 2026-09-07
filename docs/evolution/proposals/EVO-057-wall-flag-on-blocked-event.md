# EVO-057 — Mark whether the wall showed on the `blocked` event

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: native `accessibility/DetoxoAccessibilityService.kt` + `blocking/shared` (`BlockEvent`) + `core/services/firebase/analytics`
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: S

## Why
`BLOCK_SCREEN` is a wall policy, so the `blocked` event's `mode` reports `PRESS_BACK` for it
(the navigation really is a back press). Analytics could not tell whether the chosen mode
rendered its wall, or whether a forced wall was suppressed by a missing grant.

## Expected user impact
None directly. Peripheral: lets the team see whether Block screen mode is used and whether the
wall actually appeared.

## Technical complexity
Contract change: the `blocked` event gains `wall: Boolean`. Dart `BlockEvent.wall` (default
false, so older payloads parse), `AnalyticsService.logBlockTriggered(wall:)`,
`AnalyticsParam.wall` (1/0, the `enabled` idiom). Doc row in `18-platform-channel-contracts.md`.

## Performance impact
One boolean in a map already allocated per debounced block.

## Business value
Peripheral — measurement, not intervention. Cheap because it rides the toast change (EVO-056).

## Rejected alternative
Report `mode: "BLOCK_SCREEN"` in the event when the stored mode is Block screen. Lost: the event
would lie about the navigation performed, and `resolveBlockMode` never returns that token.

## Rollback
Drop the map entry; Dart defaults to false. No persisted state.

## Implementation Plan

### Current state
Event map `{package, platformId, mode, today, total, reason}`; `BlockEvent(platformId,
packageName, mode, timestamp)`; `logBlockTriggered(platform, mode)`.

### Target state
Event map adds `"wall" to shown`; `BlockEvent.wall`; `logBlockTriggered(..., wall: bool = false)`
logging `wall: 1/0`; `NativeEventReporter` forwards `event['wall'] as bool? ?? false`.

### Repo conventions to follow
`AnalyticsParam.enabled` (bool as 1/0); `native_event_reporter_test.dart` mocktail stubs.

### Steps
1. Native map entry. 2. `BlockEvent.wall` + parse. 3. Analytics param + service + reporter.
4. Update the two analytics tests. 5. Doc 18 event table, 12 analytics.

### Boundaries
No new event type. If the cited code has drifted from commit 185c7f7, STOP and report.

### Validation
- [x] analyze / test / boundaries clean (reporter + service tests updated and green)
- [x] Invariants grep clean; no new manifest permission; no new failure path
- [x] `/docs-sync` run
