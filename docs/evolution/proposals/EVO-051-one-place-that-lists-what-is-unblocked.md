# EVO-051 — One place that lists what is currently unblocked

- Status: approved
- Tier: 2 (enhancement)
- Feature: `lib/features/limits/unblock`, `lib/features/dashboard`
- Commit: 190042a
- Date: 2026-09-06
- Effort: S

## Why

M8 shipped grants but no inventory of them. A grant is visible only on the row that
minted it:

- `lib/features/limits/app_blocker/presentation/app_block_screen.dart:150` — the app row's
  pill, and only for a **custom** entry (the curated section has none).
- `lib/features/limits/web_blocker/presentation/web_block_screen.dart:483` — the site row.
- **Nowhere at all for a `REEL` grant.** `UnblockTargetType.reel` is mintable from the wall
  (`pending_unblock_listener.dart:100` labels it "this feed") and appears on no screen
  afterwards, so the user cannot see it, cannot time it and cannot end it early.

A user who granted three targets in one evening has no single view and no way to end them
together. `UnblockState.active` already holds exactly that list, derived and re-emitted on
every lapse (`unblock_cubit.dart:66`); nothing renders it.

## Expected user impact

The comparison table in `docs/info_docs/01-product-overview.md` sells Detoxo against
"easy to ignore or turn off", and the Pause copy promises "no way to *forget* to
re-enable". Today you cannot forget to re-enable, but you *can* forget what you opened —
which is the same failure wearing a different hat. One card, on the surface the user
already opens, that says what is open and offers one tap to close it.

## Technical complexity

Dart only. No channel key, no storage key, no native change, no new route. One widget
under `lib/features/limits/unblock/presentation/widgets/`, rendered by the dashboard the
way `rules_card.dart` is. The cubit is already app-wide and already exported from the
`limits` barrel, so no boundary change.

## Performance impact

None on the hot path: the accessibility service is not involved. On screen, one
`BlocBuilder<UnblockCubit>` over a list capped at `maxTemporaryUnblocks = 50` and in
practice 0–3 rows; the card returns `SizedBox.shrink()` when `active` is empty, so the
overwhelmingly common case costs one equality check.

## Business value

Defends the honesty claim that is the product's differentiator
(`01-product-overview.md`, "Why Detoxo is different" → *"Easy to ignore or turn off"* vs
*"keep future-you honest"*). It also makes the M8 feature discoverable: a mechanism whose
state is invisible reads as unreliable.

## Rejected alternative

A persistent notification listing live grants. Lost because it needs no new permission but
does need a second notification channel beside `detoxo_protection_channel`, it competes
with the FGS notification the service already owns, and it puts a one-tap bypass affordance
in the shade — the opposite of friction at the moment of temptation.

## Rollback

Delete the widget and its one call site in the dashboard. No schema, no wire, no
migration — a pure read of state that already exists.

## Implementation Plan

### Current state

`lib/features/dashboard/presentation/dashboard_screen.dart` composes cards; `rules_card.dart`
is the exemplar for a card that reads an app-wide cubit and hides itself when empty.

`UnblockState.active` (`unblock_cubit.dart:66`) is the derived live list.
`UnblockCubit.endEarly(type, id, {alsoEnd})` cancels one.

### Target state

`lib/features/limits/unblock/presentation/widgets/active_unblocks_card.dart`:

- `BlocBuilder<UnblockCubit, UnblockState>` with
  `buildWhen: (p, c) => p.active != c.active`.
- Empty `active` → `SizedBox.shrink()`.
- Otherwise a `GlassCard` titled **"Allowed right now"**, one row per grant:
  a type icon, the target's label, `Until <clock>` via `RuleSummary.clock`, and a
  **Resume** action calling `endEarly`.
- Labels: `APP` → the package (no installed-apps scan on this path);
  `WEBSITE` → the host; `REEL` → the `platformId`.
- Rendered in the dashboard beside the rules card.

### Verification

- `test/temporary_unblock_test.dart` already pins that `active` changes props on a lapse.
- New widget test: the card is absent with no grants, lists two grants when they exist, and
  a Resume tap removes exactly one row.
- `bash tool/dev.sh precommit`.
- `/docs-sync`: `docs/code_docs/31` §2, `docs/code_docs/01` (dashboard),
  `docs/info_docs/02` §18.
