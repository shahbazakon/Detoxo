# EVO-052 — Make overrides visible: the cost before, the history after

- Status: approved
- Tier: 2 (enhancement)
- Feature: `lib/features/limits/unblock`, `lib/features/limits/rules`
- Commit: 190042a
- Date: 2026-09-06
- Effort: S

## Why

M8 stores a real record of every override and renders almost none of it. `BypassEntry`
carries `kind`, `atMs`, `untilMs`, `ruleId` and one of six `OverrideReason` tokens
(`bypass_entry.dart:37`), kept newest-first and pruned to 50. The only thing the UI shows
is a bare remaining count on the override tile in the rule editor
(`rule_editor_screen.dart:842`), and only while that one rule is open.

So the user is asked to *name a reason* — the friction that makes the mechanism work — and
that reason is then written to disk and never shown to anyone, including them. A ledger
nobody reads is a diary nobody keeps.

## Expected user impact

Two small surfaces, both from data that already exists:

- **Before**: the remaining count and the reset date wherever an override can be spent, not
  only inside one rule's editor.
- **After**: "2 overrides this week — both *Schedule change*" as a line in the Activity
  tab, beside the block-event history that already lives there
  (`docs/code_docs/28-insights.md`).

That is the "tracking **and** intervention" pairing `01-product-overview.md` names as the
differentiator, applied to the one behaviour the product currently asks the user to justify
and then forgets.

## Technical complexity

Dart only, read-only over `UnblockState.ledger`. No new storage key, no channel key, no
native change. Insights already renders a local, on-device fold; this is one more row in
that shape.

## Performance impact

None on the accessibility hot path. A fold over a list capped at 50, on screen open.

## Business value

Turns a rationing mechanic into a self-knowledge feature at near-zero cost, and makes the
override's friction legible — a reason the user will see again is a reason they weigh
differently when they pick it. Supports the store-listing "tracking **and** intervention"
claim (`01-product-overview.md`, "Why Detoxo is different").

## Rejected alternative

Surfacing overrides as a chart or a streak-style score. Lost because a *count of failures*
rendered as a score is the shame-chart pattern `01-product-overview.md` explicitly rejects
("No shame charts"). A plain sentence with the reasons the user chose themselves is not.

## Rollback

Delete the two widgets. Nothing is written, so there is nothing to migrate back.

## Implementation Plan

### Current state

`UnblockState.ledger` (`unblock_cubit.dart`) holds the entries; `overridesLeft` and
`overridesResetAtMs` are derived on every resync. `OverrideReason.label` already carries the
user-facing string, and `override_quota_test.dart` pins that `label != wire`.

### Target state

- `UnblockQuota.overrideSummary(entries, config, nowMs)` — a pure static returning the
  count in the window and the reasons used, in the `StreakCubit.advance` idiom.
- An **Overrides** line in the Activity tab's Events segment, hidden when the count is 0.
- The remaining/reset copy factored out of `rule_editor_screen.dart` into one small widget
  so both surfaces read the same sentence.

### Verification

- `test/override_quota_test.dart`: `overrideSummary` counts only `OVERRIDE` inside the
  window, and groups reasons; empty ledger returns an empty summary.
- `bash tool/dev.sh precommit`.
- `/docs-sync`: `31` §4, `28` (Activity tab), `info_docs/02` §18.
