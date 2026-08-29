# EVO-022 — Truthful counter states (bubble grant, counting off)

- Status: done (implemented on `sensitive_protection`, commit pending)
- Tier: 2 (enhancement) — approved by the user in-session ("i approved all",
  2026-08-29)
- Feature: content_counter, additional_feature/appearance, dashboard
- Commit: 424a8f6 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-29
- Effort: S

## Why
The EVO-014 rule — a status surface never lies under a hiccup — had three holes
left in the counter:

1. `appearance_screen.dart` wrote the bubble switch ON *before* the overlay grant
   was known and never re-checked; deny the system prompt and the switch read ON
   with no bubble, forever (`_applyBubble`, old L88-93).
2. The Activity card's empty state promised "open Reels or Shorts and they'll
   appear here" with **Count short videos** off — nothing can appear.
3. The dashboard ring read a reassuring "0m" with counting off (usage-time
   accrual stops with the counter, `ContentCounter.onAppActivity`), and the
   "days under your limit" streak advanced daily on that zero
   (`dashboard_tab.dart` `StreakCubit.observe`).

## Expected user impact
The awareness on-ramp — the surfaces the user meets before ever turning blocking
on — never silently lies: the bubble card says it needs "Display over other
apps" and tapping it opens the grant; the Activity card and the ring say
"counting off" instead of showing zeros; the streak stops crediting unmeasured
days.

## Technical complexity
Dart only; no channel, storage or native change.

- `ContentCount.overlayGranted: bool?` (tri-state like the permission model;
  `null` = unread / unanswered, never rendered as denied) and
  `bubbleBlocked` (`enabled && bubbleEnabled && overlayGranted == false`).
- `BubbleRepository.canShow()` → `Future<bool?>` via the channel's tri-state
  `invokeBoolOrNull`.
- `ContentCounterCubit(repo, bubble)` owns both switches: `setEnabled`,
  `setBubbleEnabled` (optimistic emit → native → grant read → system prompt if
  denied), `requestOverlay()`, and re-reads the grant on every `refresh()` —
  which `AppResumeSync` already calls on every resume, so coming back from the
  system screen clears the state with no new plumbing. Streamed counts keep the
  known grant.
- Appearance bubble card: a warning row ("Needs “Display over other apps” — tap
  to allow") when `bubbleBlocked`. Activity card: counting-off copy. Dashboard:
  `measured = counter.enabled` gates the ring, the "—" values, and the streak
  `observe` call.

## Performance impact
One extra `canDrawOverlays` channel read per app resume / counter refresh
(off the accessibility hot path). Nothing per event.

## Business value
`docs/info_docs/01-product-overview.md` — the counter is the "awareness by
default" pitch; a number or switch that lies is the fastest way to lose the
trust the intervention loop depends on.

## Rejected alternative
A toast on denial ("Bubble needs Display over apps") — disappears in seconds,
leaves the switch lying, and can't be re-triggered without toggling again.

## Rollback
Revert the cubit / entity / three screen edits; no data involved.

## Implementation Plan (as shipped)

### Steps
1. `content_count.dart` — `overlayGranted`, `bubbleBlocked`, `copyWith`.
2. `bubble_repository.dart` / `bubble_repository_impl.dart` — tri-state
   `canShow()`.
3. `content_counter_cubit.dart` — second repo, `setBubbleEnabled`,
   `requestOverlay`, grant read on refresh; `main.dart` passes
   `sl<BubbleRepository>()`.
4. `appearance_screen.dart` — `_CounterSection` reads the cubits; `_SurfaceCard`
   `notice` / `onNotice`.
5. `reel_counter_card.dart` — counting-off copy.
6. `dashboard_tab.dart` — `measured` gate on ring, values and streak.
7. Tests: `test/content_counter_test.dart` (cubit: denied → prompt; unanswered →
   unknown, never blocked).

### Validation
- [x] `bash tool/dev.sh precommit` passes
- [x] Cubit paths pinned by tests
- [ ] Device: deny the overlay prompt → card shows the notice; grant it in
      Settings, return → notice clears on resume.
