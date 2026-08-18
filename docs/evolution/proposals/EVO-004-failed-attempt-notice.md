# EVO-004 — "While you were away" failed-attempt notice

- Status: proposed
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/features/access_protection
- Commit: d0ab47e
- Date: 2026-08-08
- Effort: S

## Why

The lockout ladder counts failures (`pin_config.dart` `retryCount`) but the owner never
learns someone tried: after a correct unlock the count silently resets
(`pin_cubit.dart` `verify()`).

## Expected user impact

On unlock after failed attempts: a one-line notice — "2 wrong attempts since you last
unlocked" (with the last-attempt time). Awareness is the product's second pillar;
honestly peripheral to the intervention loop, but cheap trust-building on the lock
surface.

## Technical complexity

Dart-only. `PinConfig` gains `lastFailureAt: DateTime?` + `failuresSinceUnlock: int`
(additive JSON keys, migration-free); `verify()` maintains them; the lock screen (or
the first screen after unlock) shows a dismissible banner via design_system components.

## Performance impact

None — two extra fields on an already-persisted config, written on paths that already
write it.

## Business value

Supports the "Make it stick" story (`docs/info_docs/01`); differentiates the lock from
a dumb keypad. No store-listing change needed.

## Rejected alternative

Intruder photo capture (front camera on N failures) — a real market feature, but it
drags in the CAMERA permission and a privacy story that contradicts the app's
"nothing leaves your device, minimal permissions" stance.

## Rollback

Revert cleanly; additive JSON keys, no one-way doors.

## Implementation Plan

<!-- Fill this section ONLY once Status: approved. -->
