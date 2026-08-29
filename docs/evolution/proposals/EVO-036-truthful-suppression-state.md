# EVO-036 — Render notification suppression truthfully when the grant is missing

- Status: done
- Tier: 2 (enhancement)
- Feature: `lib/features/settings`, `lib/features/permissions`
- Commit: 190042a
- Date: 2026-09-04
- Effort: S

## Why

The Notification silence switch has a permission dependency, so "on" and "working" are two
different things — and the shipped code rendered them identically.
`settings_screen.dart` bound the tile straight to `settings.suppressNotifications`, and
`_setSuppressNotifications` committed `true` after `requestPermission` regardless of outcome.
A user who proceeded past the disclosure but never enabled Detoxo in Android's list, or who
later revoked the grant from system settings, saw a switch reading ON while nothing was
being muted.

## Expected user impact

The row states its real state and offers the fix. Peripheral to the interception loop, but
load-bearing for trust: this is the app's broadest permission, and a switch that overstates
what it is doing is worse here than anywhere else in the product.

## Technical complexity

Dart presentation only. No channel key, no storage key, no native change.

## Performance impact

None on any hot path — one `BlocBuilder` over the already-app-global `PermissionsCubit`,
rebuilt on screen open and on resume, which the screen already triggers.

## Business value

Directly extends EVO-014 ("render permission/service unknown states truthfully") and
EVO-022 (truthful counter-bubble states) to the last on/off control in the app that had a
permission dependency and did not follow the precedent.

## Rejected alternative

Gate the commit on a post-request grant re-read and snap the switch back to OFF. Lost
because `requestPermission` resolves while the user is still standing on Android's list —
it would have flipped the switch off under a user who was in the middle of granting it.

## Rollback

Delete `_SuppressionTile` and restore the inline `AppToggleTile`. No persisted state.

## Implementation Plan

### Target state
- `requestPermission` returns `Future<bool>` — `false` when the user declined the
  disclosure or was routed to the restricted-settings sheet.
- `_setSuppressNotifications` returns without committing when the disclosure was declined
  (an explicit refusal), and commits otherwise.
- `_SuppressionTile` computes `blocked = enabled && !cubit.effectivelyGranted(status)` and,
  when blocked, renders a warning-toned `GlassListTile` — *"Needs 'Notification access' /
  Nothing is being muted yet — tap to allow"* — routed back through `requestPermission`.
- `effectivelyGranted`, not `granted`, so a flaky `unknown` read never accuses a working
  setup (EVO-014's `lastKnownGranted` fallback).

### Verification
`flutter analyze`, `flutter test`, `bash tool/check_boundaries.sh`. Device: toggle on and
decline the disclosure (no commit) · proceed and back out of Android's list (notice shows) ·
grant and return (notice clears on resume) · revoke mid-session (notice returns).
