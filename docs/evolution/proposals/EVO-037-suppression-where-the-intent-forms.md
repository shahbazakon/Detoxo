# EVO-037 — Offer Notification silence on the App Blocker screen

- Status: done
- Tier: 2 (enhancement)
- Feature: `lib/features/limits/app_blocker`
- Commit: 190042a
- Date: 2026-09-04
- Effort: S

## Why

Notification silence existed at exactly one place, `Settings → Privacy`. The screen where
the user actually forms the intent — locking an app in the App Blocker — said nothing about
it. Verified absent: `app_block_screen.dart` had zero occurrences of "notif", and the
dashboard carried no suppression state. A permission granted from the funnel also produced
no visible change anywhere, because the grant does not flip the setting.

## Expected user impact

A user who has just locked an app learns, at that moment, that the app can still notify them
and that one switch stops it. This is the intervention loop: a lock the app can shout
through is a half-closed loop.

## Technical complexity

One screen-local widget. `app_block_screen.dart` already imports `SettingsCubit`
(a grandfathered baseline entry), so reading `suppressNotifications` adds no new boundary
violation — `tool/boundaries_baseline.txt` stays at 7.

## Performance impact

None — a `context.watch` on an already-global cubit, on a screen that already watches it.

## Business value

Activation for a shipped-but-invisible capability, at the one moment the user's intent is
unambiguous. Reinforces "Blocks the reels, not the app"
(`docs/info_docs/01-product-overview.md`): the lock is the app-level decision, and this is
its missing half.

## Rejected alternative

A dashboard status card. Lost because the dashboard is about live protection state, not
configuration discovery, and the intent forms in the App Blocker, not on the home screen.

## Rollback

Delete `_SuppressionHint` and its call site; drop the two added imports.

## Implementation Plan

### Target state
`_SuppressionHint` renders below the custom-locks section, and **only** when at least one
lock is enabled **and** `suppressNotifications` is off — so it disappears once it has done
its job and never appears for a user with no locks. Copy: *"Locked apps can still notify you
/ Turn on Notification silence in Settings → Privacy"*, tapping routes to `Routes.settings`.

### Verification
`flutter analyze`, `bash tool/check_boundaries.sh` (must stay at 7 known). Device: no locks
→ hidden · add a lock → appears · enable suppression → disappears.
