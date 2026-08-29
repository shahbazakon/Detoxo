# EVO-014 — Render permission/service `unknown` states truthfully

- Status: done (implemented on `sensitive_protection`, commit pending)
- Tier: 2 (enhancement) — approved by the user in-session ("I approved all", 2026-08-27)
- Feature: lib/features/permissions, lib/features/dashboard, lib/core/design_system
- Commit: fb23a68 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-27
- Effort: S

## Why
The tri-state permission model (`PermissionState.unknown` = "the read didn't
answer", not "denied") landed with the persistence work, but every UI surface
still collapsed `unknown` into the red denied states:

- `permission_card.dart` was binary (`granted` bool): unknown rendered as a
  "Grant" button beside the red "Required" pill.
- `permissions_screen.dart:60` counted only live-granted for the "N of M"
  progress row, while the Continue button used `allRequiredGranted` (which
  honors the persisted granted-set) — so a flaky cold start showed "0 of 2"
  with an enabled Continue.
- `protection_status_card.dart` rendered anything ≠ `ServiceStatus.running` as
  the danger "Protection off" card — and `ServiceSnapshot()`'s default status
  IS `unknown`, so the scare card flashed on every cold start.

## Expected user impact
No more false "your protection is broken" moments after restarts or flaky
channel reads — the exact complaint that started the persistence work. A card
that cries wolf teaches the user to ignore the real outage alert.

## Technical complexity
Dart only. `PermissionCard` gains an `unknown` flag (neutral "Checking…" row);
`PermissionsCubit.effectivelyGranted` is the single predicate shared by the
gate, the progress row and the cards; `ProtectionStatusCard` gains a neutral
`unknown` branch. No channel or storage contract changes.

## Performance impact
None — render-path only, off the accessibility hot path.

## Business value
`docs/info_docs/01-product-overview.md` sells dependable, always-on
intervention; a status surface that lies under a hiccup undermines exactly
that trust.

## Rejected alternative
Keep the binary UI and make the gate stricter (block until live reads settle)
— reintroduces the restart re-ask problem the tri-state model just fixed.

## Rollback
Revert the three widget/cubit edits; no data migration involved.

## Implementation Plan (as shipped)
- `lib/features/permissions/presentation/permissions_cubit.dart` — public
  `effectivelyGranted(PermissionStatus)`; `allRequiredGranted` delegates to it.
- `lib/core/design_system/components/permission_card.dart` — `unknown` param;
  neutral sync-icon "Checking…" row when set (granted wins over unknown).
- `lib/features/permissions/presentation/permissions_screen.dart` — progress
  row and cards read `effectivelyGranted`; cards pass `unknown`.
- `lib/features/dashboard/presentation/widgets/protection_status_card.dart` —
  `ServiceStatus.unknown` renders a neutral "Checking…" card before the
  running/stopped branches.
- Tests: `test/permission_unknown_ui_test.dart` pins all three PermissionCard
  states and all three ProtectionStatusCard states.
