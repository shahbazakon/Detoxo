# EVO-032 — Exclude protected apps from Insights

- Status: done
- Tier: 2 (enhancement)
- Feature: analytics/insights + protected_apps
- Commit: 190042a (working tree; stamp the hash on commit)
- Date: 2026-09-04
- Effort: S

## Why
Per-app usage read from UsageStatsManager named the user's banking / UPI / password apps in the Insights top-app list and persisted them for 90 days in usage_daily. docs/code_docs/24-protected-apps.md §6 lists 'no UsageStats' as a privacy guarantee of the protected-apps design; that stopped being true the moment a second feature read UsageStats.

## Expected user impact
The apps a user deliberately hid never appear on screen and never reach disk. Their time still counts toward the day's aggregate, so the total keeps matching Digital Wellbeing.

## Technical complexity
Dart only. computeDailyStats takes protectedPackages and filters topApps; InsightsRepositoryImpl gains ProtectedAppsRepository and reads protectedPackagesFor on each recompute. No channel key, no native change, no storage-schema change (fewer rows, same shape).

## Performance impact
One extra Hive read per recompute, off the accessibility hot path. Nothing on a per-event path.

## Business value
Directly protects the promise in docs/info_docs/04-faqs.md ('Can Detoxo see my banking or payment apps?'), which is the trust argument behind the whole accessibility grant.

## Rejected alternative
Filtering natively in UsageQuery.appUsage — rejected: the protected set lives in Dart, native would need it pushed and kept in sync, and the rules limiter legitimately needs unfiltered per-app time.

## Rollback
Revert the protectedPackages parameter and the repository dependency. No migration: stored documents simply regain rows on the next recompute.

## Implementation Plan
Implemented in the 2026-09-04 evolution run; see `docs/code_docs/28-insights.md`
(and `25-block-screen.md` for EVO-034) for the shipped behaviour, and the tests
listed there for the pinned contract.
