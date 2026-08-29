# EVO-042 — Tell the truth when the soft nudge cannot render

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement)
- Feature: `lib/features/settings`, `lib/features/permissions`
- Date: 2026-09-04
- Effort: S

## Why

The Soft nudge switch has a permission dependency, so "on" and "working" are two different
things — and the shipped code rendered them identically. `settings_screen.dart` bound a bare
`AppToggleTile` straight to `settings.nudgeEnabled` with no permission read and no funnel.

The nudge draws its card in a `TYPE_APPLICATION_OVERLAY` window. Without "Display over other
apps" `NudgeOverlay.show` returns false, logs once, and the service deliberately reports
nothing ("report nothing, because nothing happened"). Net effect: the switch reads ON, the
tuning row reads "5 min · up to 4 per app a day", and not one card can ever appear.

## Expected user impact

High. Today a user can believe a protection is running while it is structurally inert. The
row now states its real state and offers the fix inline.

## Technical complexity

Low. Two precedents exist, one of them ~100 lines below in the same file:
`_SuppressionTile` (EVO-036) for the shape, and `ContentCount.bubbleBlocked` (EVO-022) for
this exact grant. Dart presentation only — no channel key, no storage key, no native change.

## Performance impact

None. One `BlocBuilder` over the already-app-global `PermissionsCubit`, which this screen
already rebuilds on open and on resume.

## Business value

Completes the "honest states" line the product sells (`info_docs/01-product-overview.md`:
Insights "shows you nothing rather than a screen of zeros"). Leaving one control overstating
itself undoes the trust the other three earn.

## Rejected alternative

Funnelling the grant on toggle-on (the `_setSuppressNotifications` shape). Rejected: the
nudge is advisory, and a permission sheet thrown at a user who just flipped a minor switch is
heavier than the feature. The row-level notice is dismissible-by-ignoring and self-clears on
the next resume.

## Implementation plan

1. `_NudgeTile` in `settings_screen.dart`: `BlocBuilder<PermissionsCubit, …>` reading
   `AppPermission.overlay` via `cubit.effectivelyGranted` (EVO-014 fallback, so a flaky
   channel read never accuses a working setup).
2. `blocked = enabled && !effectivelyGranted` tints the leading icon `AppColors.warning` and
   appends a `GlassListTile` "Needs *Display over other apps*" → `requestPermission`.
3. The tuning row moves inside the same widget so toggle + dependents are one unit, matching
   `_PinTile` and `_SuppressionTile`.
