# EVO-020 — Reel identity from the settled pager page + 1 s dwell (awareness counter)

- Status: done (implemented on `sensitive_protection`, commit pending — DEVICE
  CALIBRATION + QA OUTSTANDING, see the checklist)
- Tier: 2 (changed threshold + a `ponytail:` ceiling + a One Reel gate input) —
  approved by the user in-session (threshold "~1 s settled dwell", One Reel gate
  "reuse the classifier", 2026-08-28)
- Feature: content_counter (native `engine/ContentCounter.kt`, new
  `engine/ReelTracker.kt`), `accessibility/DetoxoAccessibilityService.kt`
  (counting pass, One Reel scroll capture), FAQ copy
- Commit: 424a8f6 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-29
- Effort: M (one new pure-Kotlin state machine + JVM test, two edited Kotlin
  files, copy/docs, a device calibration session)

## Why
The counter's rule was "a reel-surface detection starts a 2 s timer; any
`TYPE_VIEW_SCROLLED` cancels it; when it fires, count only if a detection landed in
the last 2 s". The only signal that reached the counter was a package name.
Reading the code end to end, the rule failed exactly where a doom-scroll counter
must not:

1. **Passive watching was never counted** — the timer's staleness check dropped a
   reel whose UI went quiet after landing and never retried
   (`ContentCounter.onDwellElapsed`).
2. **The same reel counted twice** — a comments-sheet scroll, a caption expand or
   a half-swipe that snapped back all read as "next reel" (any scroll ended the
   dwell; only the One Reel gate debounced this).
3. **Detours recounted** — replying to a notification or opening the keyboard
   (the IME window's `WINDOW_STATE_CHANGED` carries the IME's package) ended
   the reel; coming back started it again.
4. **Bubble off → reels missed** — `onNoReelSurface` ignored leave-evidence
   unless the bubble was visible, so after leaving to the feed the next reel
   opened by tap never counted.
5. **Fast doom-scrolling was under-counted by design** — 2 s was a *noise filter*
   for the noisy scroll signal, not a "you saw it" threshold.
6. **Feed browsing paid a full DFS ~6×/s** — the counting pass re-walked the
   window every 150 ms to learn "still no reel".

Every `TYPE_VIEW_SCROLLED` event already carries the pager's own visible-page
range (`fromIndex`/`toIndex`, populated by RecyclerView / ViewPager) — a free,
IPC-less per-reel identity that was being thrown away.

## Expected user impact
The bubble / widget / dashboard number is honest while doom-scrolling: reels you
stop on for about a second count once each; passive watching counts; comments,
captions, half-swipes, keyboard and quick app switches never inflate it; leaving
and re-entering reels counts the new reel even with the bubble off. Lower
background CPU on non-reel screens. The One Reel / Unblock allowance can no
longer be burned by scrolling the comments of the allowed reel.

## Technical complexity
Native only; no channel, storage-key or Dart data changes.

- `engine/ReelTracker.kt` (new, Android-free): session + settled-page identity +
  dwell state machine. Records the latest scroll snapshot, classifies it after a
  300 ms quiet window (`settledPage`: `toIndex − fromIndex ≤ 1` → page =
  `fromIndex`; multi-item list → ignore; `−1` → legacy any-scroll + dwell
  debounce, suppressed once the app's pager has reported pages). Counts when a
  reel has been the current page for `MIN_VIEW_MS = 1000` with no
  leave-evidence; belt-and-braces count on leave. `suspend()` on an app switch
  (resume within 60 s = same reel), `pause()` when `PowerManager.isInteractive`
  is false at tick time. Per-session `countedPages` de-dup. Single deadline
  (`nextDueAtMs`) for one Handler runnable.
- `engine/ContentCounter.kt`: dwell state machine replaced by the tracker;
  `onScroll(pkg, fromIndex, toIndex, deltaY)`; `onNoReelSurface` processes
  leave-evidence regardless of bubble visibility; monotonic clock for dwell.
- `DetoxoAccessibilityService.kt`: forwards the scroll fields (+ a
  `Log.isLoggable`-gated calibration line); counter-pass cadence
  `COUNT_THROTTLE_MS = 400` with `WINDOW_STATE_CHANGED` bypass (block-path
  `THROTTLE_MS` untouched — Guardrail 8); IME package is not a foreground change
  for the counter; One Reel capture stamps `lastScrollAtMs` only when
  `ReelTracker.settledPage` differs from `oneReelPage`.
- `build.gradle.kts`: `testImplementation("junit:junit:4.13.2")` — the repo's
  first native unit tests (`ReelTrackerTest`, 23 scenarios).
- Copy: counter FAQ + three info-doc passages ("about a second"); One Reel copy
  ("a couple of seconds") unchanged — the allowance keeps its own 2 s dwell.

## Performance impact
Pre-throttle scroll path: four int compares + one field write per event.
Counter-pass DFS on non-reel screens: −60 % (400 ms vs 150 ms cadence) with
blocking off; unchanged with blocking on (the block pass still walks at 150 ms and
the per-event memo shares the result). One Handler post per scroll/settle/dwell
edge instead of per detection. Device numbers pending (`bash tool/qa.sh -d
<serial> perf` vs the baseline).

## Business value
"Awareness by default" only works if the number is trusted. The counter is the
product's on-ramp (on by default, no blocking needed) and its headline stat.

## Rejected alternatives
- **Sum `scrollDeltaY` over a burst as the advance signal** — the system keeps one
  pending scroll event per service and restarts its 100 ms timer on each new one,
  so intermediate deltas are dropped; sums are lossy (verified against AOSP
  `AbstractAccessibilityServiceConnection.notifyAccessibilityEvent`). Only the
  final event's delta sign is used (first-settle snap-back detection).
- **`fromIndex == toIndex` as the "settled" test** — a pager with a 1 px peek or
  item decoration reports `(n, n+1)` even at rest (strict bounds check in
  `LinearLayoutManager.findOneVisibleChild`); `toIndex − fromIndex ≤ 1` + a quiet
  window is robust to both geometries.
- **`ACTION_SCREEN_OFF` receiver ending the session** — lock → unlock on the same
  reel would recount it. `PowerManager.isInteractive` at tick time pauses instead.
- **Keep 2 s** — with identity doing the de-dup, 2 s only hid sub-2 s
  doom-scrolling; the user chose 1 s. `MIN_VIEW_MS` stays the single knob.
- **A per-platform pager view-id in `platforms_config.json`** — would close the
  one-or-two-item inner-list ceiling but is a schema change; deferred.
- **Wiring the One Reel gate to `ReelTracker` itself** — the gate must work with
  the counter disabled; the page filter on its scroll capture is the one-line
  reuse that keeps it independent.

## Rollback
Revert `engine/ContentCounter.kt`, `accessibility/DetoxoAccessibilityService.kt`,
delete `engine/ReelTracker.kt` + `ReelTrackerTest.kt`, drop the gradle line,
restore the four copy sites. No data involved (`cc_*` keys untouched).

## Device QA checklist (required before release)
Calibration first — `adb shell setprop log.tag.DetoxoService DEBUG` then
`adb logcat -s DetoxoService:D | grep scroll`; per app note the at-rest pair after
a swipe (`(n, n)` or `(n, n+1)` are both fine — it must shift by exactly one per
advance and return to the same pair on a snap-back):
- [ ] Instagram Reels: one final line per swipe; comments `to − from ≥ 2`;
      caption expand `from = −1`.
- [ ] YouTube Shorts: RecyclerView pairs as above.
- [ ] TikTok: `(n, n)` from the moment of release.
- [ ] Snapchat Spotlight: `from = −1` (legacy path) — note whether `scrollY` moves.
- [ ] A continuously scrolling marquee/ticker does not starve the final scroll
      event; note how often a `to − from ≤ 1` pair comes from a non-pager list.

Scenarios (`adb logcat -s DetoxoService` for `contentCounted` + the bubble):
- [ ] Swipe 5 reels at ~0.5 s each, stop on the 6th → +1.
- [ ] Land and hands-off 10 s → +1 at ~1 s, none after.
- [ ] Open / scroll / close comments, expand caption → +0.
- [ ] Half-swipe snap-back (incl. the first swipe after entering by tap) → +0.
- [ ] Fling 4 pages → +1.
- [ ] Lock 0.5 s after landing, unlock 30 s later → +1 after ~1 s more.
- [ ] Reply to a WhatsApp notification, back within 60 s → +0; after > 60 s → +1.
- [ ] Type a comment (keyboard up), keep watching → +0.
- [ ] Bubble OFF: leave to feed, re-enter by tap, watch → +1.
- [ ] Feed browsing: bubble appears ≤ ~400 ms after landing on a reel.
- [ ] One Reel allowance 1: scrolling comments on the allowed reel does not
      block; the next swipe does.
- [ ] `bash tool/qa.sh -d <serial> perf` vs baseline: no regression.
