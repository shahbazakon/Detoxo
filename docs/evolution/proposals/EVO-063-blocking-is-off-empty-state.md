# EVO-063 — Say "Blocking is off" instead of "No blocks yet today" when the service is stopped

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/analytics` (presentation), reading `ServiceCubit` via the `blocking` barrel
- Commit: 185c7f7 (working tree uncommitted — the Activity restructure and its Tier-1 batch of 2026-09-07 are not yet committed)
- Date: 2026-09-07
- Effort: XS

## Why
`lib/features/analytics/presentation/widgets/by_app_section.dart:127`:
```dart
        ByAppSegment.blocks => 'No blocks yet today.',
```
states zero as a fact without consulting `ServiceCubit.state.status`
(`enum ServiceStatus { running, stopped, unknown }`,
`lib/features/blocking/shared/domain/entities/enums.dart:231`). With the accessibility service
stopped or the grant revoked, a clean day and a day with no protection read identically — the
confident-lie class EVO-014 removed from screen time and EVO-022 removed from the reel counter
("Counting is off — …", `by_app_section.dart:122-124`). The Today tile's "Blocked today: 0" has
the same ambiguity but a tile has no room for the reason; the segment's empty sentence does.

## Expected user impact
With the service stopped, the Blocks segment reads "Blocking is off — turn Detoxo on to see
where it steps in." with a **Turn on** action that runs the existing enable flow; with the status
unknown (boot window, channel hiccup) it reads "Checking…" and offers nothing. A genuinely clean
day still reads "No blocks yet today." Directly serves the intervention loop: the screen that
reports blocks now also tells the user when there is no blocker running.

## Technical complexity
Dart only. `ServiceCubit` is already read by the card (`by_app_section.dart:148`) — the status
joins the `context.select` tuple. The Turn on action reuses whatever the Dashboard's status card
calls (grep `ServiceCubit` in `lib/features/dashboard/presentation/` for the enable entry point
and route through the same method; if it opens the accessibility settings walkthrough, do the
same). No channel, storage or manifest change.

## Performance impact
None. One extra enum in a `select` tuple.

## Business value
"Runs quietly, always on" (`docs/info_docs/01-product-overview.md`) is a promise the Activity
screen can quietly break by showing a zero for a stopped service. Honest states are the
product's stated stance ("Honest numbers").

## Rejected alternative
Hide the Blocks segment entirely while the service is stopped. Rejected: yesterday's and
all-time's numbers on the tile still show, so hiding the rows would look like a bug rather than a
state, and the user loses the path to turn protection back on.

## Rollback
Revert the Dart file and its test. No stored data.

## Implementation Plan

### Current state
`by_app_section.dart:115-129` — `emptyCopy(ByAppSegment segment, {required bool counting})`.
`by_app_section.dart:147-150`:
```dart
    final count = context.watch<ContentCounterCubit>().state;
    final blocks = context.select((ServiceCubit c) => c.state.blocksByPackage);
```
`by_app_section.dart:180-186` — the empty branch renders `Text(ByAppSection.emptyCopy(...))`.

### Target state
- `emptyCopy(segment, {required bool counting, required ServiceStatus service})`:
  `blocks when service == ServiceStatus.stopped` → `'Blocking is off — turn Detoxo on to see where it steps in.'`;
  `blocks when service == ServiceStatus.unknown` → `'Checking…'`; otherwise unchanged.
- The `select` becomes `(c.state.blocksByPackage, c.state.status)`.
- Below the sentence, only for `stopped`: a `SecondaryButton('Turn on')` (design system,
  `buttons.dart`) calling the Dashboard's enable entry point.

### Repo conventions to follow
- Truthful empty states: `_UsageAccessCard` (`insights_view.dart:96-134`) and the reel counter's
  "Counting is off" copy.
- Buttons from `lib/core/design_system/components/buttons.dart`; no raw `TextButton`.
- Pure copy selection stays in the static `emptyCopy` with a test.

### Steps
1. `by_app_section.dart`: extend `emptyCopy`; select the status; add the button for `stopped`.
2. `test/by_app_rows_test.dart`: the three block sentences by status.
3. `test/activity_screen_test.dart`: push `ServiceSnapshot(status: ServiceStatus.stopped)`, select
   Blocks, assert the "Blocking is off" copy and a "Turn on" button; `unknown` shows "Checking…"
   and no button.
4. Docs: `docs/code_docs/28-insights.md` §6 (the empty-segment sentence), `docs/code_docs/12-…md`
   §1, `info_docs/02` §15 (hand over).

### Boundaries
Do not change the Today tile ("Blocked today: 0" stays — the tile's semantics are the
counters'). Do not touch `ServiceCubit` or the native status. If `by_app_section.dart:115-129`
has drifted from the excerpt, STOP and report.

Drift note (2026-09-07): the line numbers have moved — the file gained a `common_widgets` import
and its build now renders `SectionHeader` + `GlassSegmented` + a `GlassCard` of rows (see
`docs/evolution/BACKLOG.md`, "Activity screen: headed sections"). `emptyCopy` itself is unchanged;
re-read the file and refresh the excerpt before executing.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: no persisted state · the revoked-accessibility path is the
      feature · offline · no new manifest permission · no new failure paths
- [ ] Native untouched; manual check: toggle the accessibility service off and on with the
      Activity tab open — the sentence follows the status on resume
- [ ] `/docs-sync` run; mapped docs updated
