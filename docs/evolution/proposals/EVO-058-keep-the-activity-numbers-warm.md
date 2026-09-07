# EVO-058 — Keep the Activity numbers warm across visits

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics` (+ `lib/main.dart` composition root)
- Commit: 185c7f7
- Date: 2026-09-06
- Effort: S

## Why

`HomeShell` builds only the active tab (`home_shell.dart:39-46`, deliberately, for the
floating bar's single scroll controller), and the Activity screen created a fresh
`InsightsCubit(...)..load()` on every mount (`analytics_screen.dart`, `_withCubit`). So every
return to the tab flashed `_Loading` ("Reading your screen time…") and re-ran two channel
queries plus a decode, an encode and a Hive write of the 90-day document — while the cubit's
own comment (`insights_cubit.dart:47-48`) says a refresh should keep the numbers on screen.
The drawer route (`app_drawer.dart` → `context.push`) stacked a second cubit on a live one,
so drawer → Activity from the tab ran two computes racing on `usage_daily`.

## Expected user impact

Returning to Activity paints the last numbers immediately and refreshes them in place; the
spinner appears once per process, on the very first open. One compute per open instead of
one per mount plus one per drawer push. Peripheral to the intervention loop, but this is the
screen the user checks most and the "smoother interaction" they asked for.

## Technical complexity

Dart only. `InsightsCubit` moves to `main.dart` as a lazy `BlocProvider` (nothing computed at
boot — the first Activity open constructs it), `InsightsView.initState` calls `refresh()`,
`_withCubit` is deleted. No storage key, no channel key, no native change.

## Performance impact

Fewer computes, not more; about 1 KB of state held for the process. Nothing on the
accessibility hot path.

## Business value

Retention on the honest-numbers surface (`01-product-overview.md`, "Honest numbers"); a
tab that flickers on every visit reads as unfinished.

## Rejected alternative

Seeding the cubit from the `usage_daily` cache on cold construction (would also cover the
first open after process start). Lost: it adds a "stale" state and a second read path to
remove a spinner that now appears once per process.

## Rollback

Restore `_withCubit` in `analytics_screen.dart` and drop the provider from `main.dart`.
Nothing is written, nothing to migrate.

## Implementation Plan

### Current state

`analytics_screen.dart` — `_withCubit` wraps both entry points in
`BlocProvider(create: (_) => InsightsCubit(sl<InsightsRepository>(), sl<EngineRepository>())..load())`.
`insights_view.dart` — `initState` only registers the lifecycle observer.

### Target state

- `main.dart`: `BlocProvider(create: (_) => InsightsCubit(sl<InsightsRepository>(), sl<EngineRepository>()))`
  beside the other app-wide cubits (default `lazy: true`; **not** `..load()`ed).
- `analytics_screen.dart`: no `_withCubit`; `AnalyticsScreen` / `AnalyticsTab` build the body directly.
- `insights_view.dart`: `initState` → `unawaited(context.read<InsightsCubit>().refresh())`.

### Repo conventions to follow

`ContentCounterCubit` / `UnblockCubit` in `main.dart` (app-wide cubits with a comment naming
their readers). Cubits never in get_it.

### Steps

1. Add the provider to `main.dart` with the comment above.
2. Delete `_withCubit`; simplify both entry points.
3. Add the `refresh()` call to `InsightsView.initState`.
4. Widget test: a second mount of `InsightsView` over the same cubit shows the numbers on
   its first frame, never the spinner (`test/insights_view_test.dart`).

### Boundaries

Do not touch `HomeShell`'s single-tab build or the scroll controller. If the cited lines have
drifted from the Commit stamp above, STOP and report — do not improvise.

### Validation

- [x] `bash tool/dev.sh precommit` passes
- [x] `tool/boundaries_baseline.txt` line count ≤ before (still 0)
- [x] New logic has a test in the repo pattern
- [x] Invariants grep clean
- [x] Production readiness: nothing persisted; works offline; no permission; no native change
- [x] `/docs-sync` run; `28` §6 and `12` §1 updated
