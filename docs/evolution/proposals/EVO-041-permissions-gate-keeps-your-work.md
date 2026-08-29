# EVO-041 — The permissions gate must not destroy in-progress work

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement) — changes when the user is redirected
- Feature: core/navigation
- Date: 2026-09-04
- Effort: S

## Why
New in M6. Gating used to be an imperative `context.go` chain the splash ran
once; it is now a global `redirect` re-evaluated on every `AppGate` notify — and
the `PermissionsCubit` listener that feeds it fires on every app resume
(`AppResumeSync` refreshes permissions each time). So losing accessibility while
the user sits at `/rules/edit` composing a schedule redirected them to
`/permissions`, destroying the editor, its unsaved rule and its `state.extra`,
with no warning. The same applies to a half-entered PIN at `/pin/setup`.

## Expected user impact
Silent data loss stops. A user who loses a permission mid-task keeps their task;
they are funnelled the next time they pass through home or relaunch.

## Technical complexity
Low. `_permissionsGateApplies` — the pass-through screens plus `/home` and
`/permissions` — gates the redirect. Everything else is left alone.

## Performance impact
None; one `Set.contains` in a redirect that already runs five bool tests.

## Business value
Protects trust at exactly the moment it is most fragile: the app has just lost
its permission AND thrown away the user's work. `pinLocked` is already a
session-scoped flag for the same reason; this makes the permissions gate
consistent with it.

## Rejected alternative
Make `permissionsOk` a launch-only session flag like `pinLocked`. Simpler, but it
would stop re-funnelling a user who revokes accessibility and returns to home —
the case where the app genuinely IS broken and should say so. Scoping by location
keeps that.

## Rollback
Remove `_permissionsGateApplies` and restore the unconditional gate.

## Implementation Plan
1. `app_gate.dart`: add `_permissionsGateApplies`; gate the permissions redirect on it.
2. `test/app_gate_test.dart`: assert a deep route is left alone while `/home` and the pass-throughs still redirect.
