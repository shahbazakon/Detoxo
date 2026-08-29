# EVO-039 — Keep the promise a skipped survey makes

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement) — changes what gets written
- Feature: onboarding
- Date: 2026-09-04
- Effort: S

## Why
`_canSkip` lets the user skip welcome and survey straight to the selection, so
`mattersMost` can be null on the commitment screen. `_promise`'s `switch` fell
through to `_`, which states — verbatim, as the last thing the user reads before
the permission grant — "Thirty minutes of feed a day. After that they stop
opening until tomorrow." But `starter_rule_sync.dart` required `matters != null`
before writing anything, then marked the record completed and cleared it. The
app made a concrete promise on screen and implemented nothing.

## Expected user impact
A skipper grants accessibility and gets the 30-minute budget they were just
promised, instead of an empty Rules screen and no signal that anything is wrong.

## Technical complexity
Low. `starterPreset(MattersMost?)` maps null to `RulePreset.doomscrollBudget` —
the same preset the copy describes — and the sync drops the null guard. The
commitment screen now renders its promise FROM that preset rather than restating
its hours, so the two cannot drift again.

## Performance impact
None.

## Business value
Protects M6's own thesis, and the product's in-the-moment differentiator
(`docs/info_docs/01-product-overview.md`): the funnel exists to end with a
working rule. A first run that ends with nothing is the failure mode the whole
milestone was built to remove.

## Rejected alternative
Give null its own honest copy ("no rule yet — set one up in Rules"). Truthful,
but it makes skipping produce nothing, which is exactly the pre-M6 behaviour;
defaulting is the option where the user is protected either way.

## Rollback
Restore the `matters != null` guard and the hardcoded `_` promise string.

## Implementation Plan
1. `starter_rule.dart`: extract `starterPreset(MattersMost?)`, null → `doomscrollBudget`; `starterRule` takes a nullable `mattersMost`.
2. `starter_rule_sync.dart`: drop the null guard from the write condition.
3. `onboarding_screen.dart`: `_CommitmentStep._promise` renders from `starterPreset(...).template` (`RuleSchedule.formatHHmm` for the window, `thresholdMs ~/ 60000` for the budget).
4. Test: `test/starter_rule_sync_test.dart` — "a skipped survey still gets the rule its promise named".
