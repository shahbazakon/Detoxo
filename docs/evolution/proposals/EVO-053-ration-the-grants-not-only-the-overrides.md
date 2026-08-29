# EVO-053 — Ration the grants, not only the overrides

- Status: approved
- Tier: 2 (enhancement)
- Feature: `lib/features/limits/unblock`
- Commit: 190042a
- Date: 2026-09-06
- Effort: M

## Why

M8 shipped two escape hatches with opposite economics:

- An **override** on a locked rule is rationed — `BypassConfig.overrideLimit = 2` per
  rolling 7 days, validated before any write (`unblock_quota.dart:157`).
- A **grant** on a target is unlimited. `UnblockCubit.grant` (`unblock_cubit.dart:236`)
  checks only that the store loaded. A 60-minute allowance on Instagram can be re-taken
  the instant it lapses, from the wall the block itself raises
  (`31-locked-rules-and-unblock.md` §5) — and each new grant *replaces* the last, so the
  countdown never accumulates evidence that it happened five times today.

The asymmetry is the part a determined future-self finds first: the commitment side is
rationed, the escape side is not. "Everything else stays protected" is then true only
per-window, not per-day.

## Expected user impact

The user picks a daily allowance per target (default: unlimited, so nothing changes for
anyone who does not opt in). Once set, the duration sheet shows what is left, and the wall's
"Allow for a while" is not offered when nothing is. Directly strengthens the
in-the-moment loop (`01-product-overview.md`, *"Steps in while you're scrolling"*): the
fourth tap of the evening is exactly the moment the product is supposed to hold.

## Technical complexity

Dart only, and it re-uses the store M8 already authored. `BypassEntry.kind` was shipped
with the discriminator from day one precisely so a second preset could be added without
renaming a persisted key (`bypass_entry.dart`, and the test at
`override_quota_test.dart` asserting `EMERGENCY` round-trips). A grant records a
`BypassKind.grant` entry; the same rolling-window arithmetic counts it.

Contract changes: one new `BypassKind` value and two new `BypassConfig` fields
(`grantLimit`, `grantPeriod`). Both are additive and read type-tolerantly, so an older
document loads with the defaults. **No channel key, no native change** — native enforces a
grant's *expiry*, never its provenance, and that separation is deliberate
(`temporary_unblock.dart:37`).

## Performance impact

None on the accessibility hot path. The quota check is a linear scan of a list already
capped at 50 (`UnblockQuota.pruneLedger`), run once per user tap.

## Business value

The highest of the four M8 follow-ups. Without it the headline promise degrades to "one
target at a time, as often as you like", which is the shape of every screen-time app the
comparison table in `01-product-overview.md` positions Detoxo against.

## Rejected alternative

An escalating cooldown (each grant on the same target costs a longer wait before the next).
Lost on two counts: it needs a second time axis in the ledger that M2.2's cooldown will
also want, risking two competing implementations, and a wait the user cannot see coming is
punishment rather than a budget. A visible count is honest; a growing invisible delay is
not.

## Rollback

Set `grantLimit` to 0 (the "unlimited" sentinel), which is also the default, and the
feature is inert. The `BypassKind.grant` rows already written stay readable and are simply
not counted — `effectiveRemaining` filters by kind. No migration either way.

## Implementation Plan

### Current state

```dart
// lib/features/limits/unblock/domain/entities/bypass_entry.dart
enum BypassKind { override('OVERRIDE'), emergency('EMERGENCY') }
```

```dart
// unblock_quota.dart — counts only OVERRIDE
static int effectiveRemaining(List<BypassEntry> entries, BypassConfig config, int nowMs)
```

`UnblockCubit.grant` writes no ledger row at all.

### Target state

- `BypassKind.grant('GRANT')`.
- `BypassConfig.grantLimit` (default **0 = unlimited**) and `grantPeriod` (default `DAY`),
  clamped on read like the existing fields (`bypass_config.dart:38`).
- `UnblockQuota.grantsRemaining(entries, config, nowMs)` — the same rolling-window count,
  filtered to `BypassKind.grant`; returns `null` when `grantLimit == 0`.
- `UnblockCubit.grant` refuses with a new `noGrantsLeft` message when the budget is spent,
  and on success appends one `BypassKind.grant` entry `{atMs, untilMs, targetId}`.
  `alsoFree` aliases record **one** entry, not one per alias — one user action, one spend.
- The duration sheet shows "N left today" when a limit is set.
- `offersUnblock` is unaffected: native cannot see the ledger, so the wall may still offer
  the button; the sheet is where the refusal is stated. Documented as the ceiling.

### Verification

- `test/override_quota_test.dart`: `grantsRemaining` at the rolling boundary; `0` means
  unlimited; an `OVERRIDE` row never spends grant budget and vice versa (the existing
  `emergency` test is the exemplar).
- `test/temporary_unblock_test.dart`: a refused grant writes nothing and reverts nothing;
  an alias grant spends exactly one.
- `bash tool/dev.sh precommit`.
- `/docs-sync`: `31` §2 and §4, `09` (the ledger document), `info_docs/02` §18, `04`.
