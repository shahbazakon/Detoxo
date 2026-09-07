# EVO-059 — Show where the blocks happened, and act on it

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics`, `lib/features/blocking/shared` (snapshot), native `engine/ConfigStore.kt` + `engine/BlockTally.kt`
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: M

## Why

The engine knows the package of every block — `DetoxoAccessibilityService.kt` posts
`package` and `platformId` on each `blocked` event — but persists only two integers
(`ConfigStore.recordBlock`: `block_today`, `block_total`). The Activity tab could say "37 blocks
today" and never "31 of them in Instagram". The reel card already answers that question per
app, and EVO-033 made the top-app row an action.

A Dart-side tally would repeat the flaw of the block-event feed this screen just lost: Dart
is not alive when the UI is dead, and the engine blocks all day with the UI dead (the web
blocker's per-host tally in `web_block_stats_repository_impl.dart` has exactly that shape).
So the tally is native.

## Expected user impact

Under the two block tiles, a **Where it happened** list: one row per app with today's count and
a bar relative to the most-blocked app, each opening the rule editor pre-filled with a daily
limit for that app (EVO-033's pattern, shared as `AppLimitRow`). This strengthens the loop
directly: the moment the user sees which app keeps pulling them back is the moment to tighten
that app's limit.

## Technical complexity

- Native: `engine/BlockTally.kt` (pure: `record` / `parse` / `without`, cap 20 by evicting the
  smallest), one new prefs key `block_by_pkg_today` in `ConfigStore` rolled with `block_date`,
  `blockStats` returns a `BlockStats` data class, `pushProtectedApps` scrubs the tally.
- Contract (both named): the `blocked` event and the `blockStats` reply gain
  `byPackage: Map<String, Int>`.
- Dart: `ServiceSnapshot.blocksByPackage`; `EngineRepositoryImpl` parses it (with `as num?`);
  `_BlockBreakdown` in `analytics_screen.dart`; labels from the engine's process-cached
  installed list, package names as the fallback.

## Performance impact

One prefs string rewrite per block, already behind the 1200 ms block debounce; ≤ 20 entries.
Zero on the per-event path. The map crosses the channel once per block (≤ 20 pairs).

## Business value

The "tracking **and** intervention" differentiator (`01-product-overview.md`, "Why Detoxo is
different"; store listing "See your habit clearly"). Competitors stop at "blocked N times".

## Rejected alternative

Tallying in Dart from `blocked` events into Hive. Lost because Dart is not alive when the UI
is dead — the counts would be exactly as unrealistic as the removed feed.

## Rollback

Drop `_BlockBreakdown`, the snapshot field and the native tally; the extra prefs key is
ignored by an older build and wiped by "Reset app data". No migration.

## Implementation Plan

### Current state

`ConfigStore.recordBlock(dateKey)` / `blockStats(dateKey): Triple<Int, Int, String>`; the two
block sites destructure `(today, total, _)`; `blockStats` arm returns `{today, total, date}`;
`ServiceSnapshot { status, blocksToday, blocksTotal }`.

### Target state

As in **Technical complexity**. Protected packages never enter the tally (the privacy guard
precedes every block) and leave it when protected later (`scrubBlockTally`).

### Repo conventions to follow

Pure Kotlin object + JVM test (`UsageQuery` / `UsageQueryTest`); EVO-049's bounded host
tally; `context.select` / `buildWhen` for the widgets; `AppLimitRow` for the rows.

### Steps

1. `BlockTally.kt` + `BlockTallyTest.kt`.
2. `ConfigStore`: key, `recordBlock(dateKey, yesterdayKey, pkg)`, `blockStats` → `BlockStats`,
   `scrubBlockTally`.
3. Both block sites + the `blockStats` arm carry `byPackage`; `pushProtectedApps` scrubs.
4. `ServiceSnapshot.blocksByPackage`; `EngineRepositoryImpl._readCounts`.
5. `AppLimitRow` extracted from `insights_view.dart`; `_BlockBreakdown` added.
6. `test/activity_screen_test.dart` pins the rows and the scroll order.

### Boundaries

Never tally a protected package; never name a package in a log line. If the cited code has
drifted from the Commit stamp above, STOP and report.

### Validation

- [x] `bash tool/dev.sh precommit` passes (incl. the native JVM tests)
- [x] baseline still empty
- [x] JVM + widget tests added
- [x] Invariants grep clean
- [x] Production readiness: the tally survives process death and reboot (SharedPreferences,
      rolled by `block_date`); works offline; no new permission; failure paths log via
      `AppLogger.e`
- [ ] Native touched → manual device sanity (owed, no device in the run that shipped this):
      service reconnect, a block in two apps shows two rows, protecting one of them removes
      its row, the tiles at 1.3× / 2.0× text scale
- [x] `/docs-sync`: `12` §1, `18`, `09`, `28` §6 updated
