# EVO-009 — "Suggested" section at the top of the add-app picker

- Status: proposed
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/core/widgets/app_picker_sheet.dart + native `channels/CommandHandler.kt` (contract change)
- Commit: f2941b5 (+ uncommitted picker work of 2026-08-14)
- Date: 2026-08-14
- Effort: M

## Why
The picker lists ~200 alphabetical apps; the app the user came to add is buried.
Both screens know what the user *probably* wants: the blocker wants the apps you
actually doomscroll, the protected list wants your bank.

## Expected user impact
The right app is one tap from the top. Blocker-side this connects directly to the
in-the-moment intervention loop — surfacing the user's most-used apps is surfacing
exactly where their time goes.

## Technical complexity
**Design decision required — two viable strategies:**
1. **Usage-ranked (recommended for the blocker):** native `UsageStatsManager` query
   (the `PACKAGE_USAGE_STATS` permission already exists in the manifest and has a
   grant flow in `features/permissions`) → add a `usageRank` or `foregroundMs` field
   to the `installedApps` payload (contract change, doc 18). Degrades gracefully when
   usage access is not granted (no Suggested section).
2. **Category-based (recommended for protected):** `ApplicationInfo.category ==
   CATEGORY_FINANCE` (API 26+) → `isFinance` flag in the payload; picker shows
   installed finance apps not already covered by the catalog under "Your bank?".
Either way: one new payload field + a sectioned list in `_AppPickerBody`. The two can
ship independently; approving this proposal means picking which (or both).

## Performance impact
Picker-open only, on the existing off-thread scan; a UsageStats query adds tens of ms
to the once-per-process enumeration. Nothing on the accessibility hot path.

## Business value
Differentiator-adjacent (product overview: steps in *while* you scroll — knowing
*where* you scroll is the same signal). Also the strongest onboarding moment for the
protected feature: "your bank" appearing pre-suggested sells the privacy promise.

## Rejected alternative
Client-side heuristics over package names (e.g. "contains 'bank'") — false positives
in every locale, and no usage signal at all.

## Rollback
Additive payload field + picker section; remove both, no persisted data.

## Implementation Plan
<!-- Fill this section ONLY once Status: approved — and name the chosen strategy. -->
