# EVO-027 — "Instagram opened 7 times today" on the block screen, from the usage layer

- Status: done (implemented 2026-09-03 in the working tree on top of 190042a; stamp the commit hash here when it lands)
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/blocking/block_screen` + native `engine/UsageQuery.kt`, `overlay/BlockScreen*.kt`
- Commit: 190042a (working tree carries the uncommitted M0/M1 delta this builds on)
- Date: 2026-09-03
- Effort: M

## Why
`PACKAGE_USAGE_STATS` is granted and readable since M0.2, and read by nothing user-visible
(`docs/code_docs/26-catalog-and-usage-signal.md` — "No UI consumer yet"). The wall has room for
one more honest number at the exact moment it matters:

`android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenRenderer.kt:364-372`
```kotlin
            val stats = ArrayList<String>(2)
            if (spec.showCount && p.todayCount >= 0 && p.referenceType == BlockScreenPayload.TYPE_REEL) {
                stats += res.getQuantityString(R.plurals.wall_count_today, p.todayCount, p.todayCount)
            }
            if (p.bankMs >= 0L) {
```

## Expected user impact
Reel and app-block walls gain a third stat line — "Instagram opened 7 times today" — a second
after the wall appears. Off by a "Times opened today" toggle in the editor; silently absent when
Usage Access is not granted.

## Technical complexity
Native: `UsageQuery.hasAccess` (the AppOps check moves out of `CommandHandler`, which delegates),
`UsageQuery.opensToday(context, pkg, nowMs)` counting foreground *transitions* into `pkg` since
local midnight (pure `countOpens` + `startOfDay` helpers, JVM-tested); the overlay runs it on a
lazy single-thread executor after a successful add and sets the line on the `WallView` (now
`internal`, with an `extraStat` setter). Payload gains `packageName` and `opensToday` on both
sides; `BlockScreenStyleSpec` / `BlockScreenStyle` gain `showOpens` (default true); plurals
`wall_opens_today`. No new channel key, no new `StoreKeys`.

## Performance impact
One `queryEvents` over today's window per block, on an IO thread, behind the 1200 ms debounce —
a few hundred rows scanned without allocation. Nothing on the accessibility event path. The wall
renders immediately; the line arrives late so the query never delays the block.

## Business value
`docs/info_docs/01-product-overview.md` — "the number you never wanted to admit" and "See your
habit clearly": the number arrives in the moment, not the morning after.

## Rejected alternative
Dart computing the count and pushing it with settings: stale between pushes, needs a poll, and
would put a `UsageStatsManager` read on the settings path.

## Rollback
Delete the two payload fields, the style field and the helpers; persisted style JSON with the
extra key still parses. No migration.

## Implementation Plan

### Current state
- `CommandHandler.hasUsageAccess()` (`channels/CommandHandler.kt:521-538`) holds the AppOps check.
- `UsageQuery` (`engine/UsageQuery.kt`) has `events()` building rows; no counting helper.
- `BlockScreenPayload` (Kotlin `BlockScreenRenderer.kt:43-56`, Dart `block_screen_payload.dart:42-56`)
  has no package field for reel walls (`referenceId` is the platform id).
- `WallView` is `private class` with an immutable `WallCopy`.

### Target state
- `UsageQuery.hasAccess(context)`, `UsageQuery.opensToday(context, pkg, nowMs)`,
  `internal fun startOfDay(nowMs, zone)`, `internal fun countOpens(events: Iterable<Pair<String, Int>>, pkg)`.
- Payload: `packageName: String = ""`, `opensToday: Int = -1` (both sides, wire keys
  `packageName`, `opensToday`).
- Spec/style: `showOpens: Boolean = true`; cubit `setShowOpens({required bool show})`; editor
  toggle "Times opened today"; `BlockScreenCopy` stat
  `'${p.appLabel} opened N time(s) today'` when `style.showOpens && p.opensToday >= 0`.
- `strings.xml`: `<plurals name="wall_opens_today">` "%1$s opened %2$d time today" / "…times today".
- Renderer: `WallCopy` renders the line when present in the payload; `WallView` is `internal`
  with `var extraStat: String` (invalidates + refreshes `contentDescription`), tagged `TAG_WALL`.
- Overlay: after a successful add, when `spec.showOpens && payload.opensToday < 0 &&
  payload.packageName.isNotBlank() && UsageQuery.hasAccess(ctx)`, run `opensToday` on the lazy
  executor and post `setOpens(payload, n)`, which is a no-op if the wall changed meanwhile.
- Service trigger sites fill `packageName` (`reelPayload`, `onAppBlocked`, `handleBrowser`).

### Repo conventions to follow
`installedApps` off-thread + post-back pattern; pure helpers pinned by `UsageQueryTest`;
Dart copy mirrored and tested in `block_screen_test.dart`.

### Steps
1. `UsageQuery`: `hasAccess`, `startOfDay`, `countOpens`, `opensToday`; `CommandHandler` delegates.
2. Payload fields both sides; service fills `packageName`.
3. Spec/style `showOpens`; plurals; `WallCopy` line; `WallView.extraStat`; overlay late fill.
4. Dart copy/preview/editor toggle; tests (JVM: `startOfDay`, `countOpens`; Dart: copy line, style round-trip).
5. Docs: `25-block-screen.md` §3/§5/§6, `26-catalog-and-usage-signal.md` (first consumer), `18` style fields, `info_docs/02` §9, `info_docs/04`.

### Boundaries
Do not add a cache, a ticker, or a Dart consumer of the usage layer (M4). If the code at the
cited lines has drifted from the Commit stamp above, STOP and report.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern
- [ ] Invariants grep clean
- [ ] Production readiness: grant-revoked path = no line, no error · offline · no manifest change · query failure swallowed (`runCatching`)
- [ ] Native touched → device sanity: line appears within ~1 s of the wall; absent with Usage Access revoked; toggle off hides it; TalkBack reads the updated backdrop
- [ ] `/docs-sync` run; mapped docs updated
