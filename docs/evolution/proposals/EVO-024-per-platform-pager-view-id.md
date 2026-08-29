# EVO-024 — Per-platform pager view-id for reel identity

- Status: done — mechanism shipped (config field → parser → service verdict →
  tracker, with a unit test), behaviour-neutral until a platform declares a
  `pagerViewId`. **No ids are shipped yet**: they are unknowable without a phone
  (no `adb` on this host), so the per-app values are filled from the EVO-020
  calibration log (`scroll … cls=… pager=…` lines). If that log shows the
  ceiling never fires on a catalogued app, leave the field unset.
- Tier: 2 (enhancement; config-schema change) — approved by the user
  in-session ("i approved all", 2026-08-29)
- Feature: content_counter (native `engine/ReelTracker.kt`,
  `accessibility/DetoxoAccessibilityService.kt`), blocking/shared config
  schema (`assets/config/platforms_config.json`, `engine/DetectionConfig.kt`)
- Commit: 424a8f6
- Date: 2026-08-29
- Effort: M (after calibration)

## Why
`ReelTracker` identifies a reel by the settled page of *any* scrolled view whose
snapshot shows ≤ 2 visible items (`settledPage`). Its documented ceiling (a):
a one-or-two-item inner list — a single-comment sheet, a one-item carousel —
settles like a pager page and can produce ≤ 1 phantom count per occurrence.
The scroll event carries the scrolled view's identity for free
(`event.className`, and `event.source.viewIdResourceName` at one binder read),
so a per-platform `pagerViewId` would let the tracker accept page indices only
from the real reel pager.

## Expected user impact
Zero phantom counts from single-comment sheets and one-item carousels — if
calibration shows they occur at all.

## Technical complexity
- `platforms_config.json`: optional `pagerViewId` per platform (doc 02 schema).
- `DetectionConfig`: parse it (qualified like `FINDBYID` ids).
- Service: on `TYPE_VIEW_SCROLLED` for a platform that declares it, read
  `event.source?.viewIdResourceName` (one IPC per **scroll event**, not per
  settle — the event is recycled before the 300 ms settle fires) and forward
  `isPager` to `ContentCounter.onScroll`.
- `ReelTracker.scroll(..., isPager)`: indexed snapshots from a non-pager view
  are treated as `NO_INDEX` (inner scroll) instead of a page.
- Fallback: platforms without `pagerViewId` keep today's behaviour.

## Performance impact
One `getSource()` binder read per scroll event on declaring platforms
(coalesced by the framework to ≤ 10/s). Must be measured with `qa.sh perf`.

## Business value
Accuracy leadership for the headline number
(`docs/info_docs/01-product-overview.md`).

## Rejected alternative
Match on `event.className` alone (no IPC) — the class is `RecyclerView` /
`ViewPager2` for the pager *and* for the comments list, so it cannot separate
them.

## Rollback
Remove the config field (ignored by older parsers) and the `isPager` plumbing.

## Implementation Plan (as shipped, 2026-08-29)

1. `engine/DetectionConfig.kt` — `PlatformRule.pagerViewId: String?`, parsed
   from `pagerViewId` (`":id/x"` → `"<pkg>:id/x"`; a value with its own package
   verbatim; blank → null).
2. `DetoxoAccessibilityService.pagerVerdict(event, platforms)` — `null` when no
   platform of the package declares an id (zero cost) or the event has no
   source; else one `event.source.viewIdResourceName` read → `true`/`false`.
   Forwarded through `ContentCounter.onScroll(…, isPager)`.
3. `engine/ReelTracker.scroll(pkg, from, to, deltaY, now, isPager)` — a
   snapshot with `isPager == false` settles as `IGNORE` (inner scroll).
   `ReelTrackerTest.indexedScrollFromAKnownNonPagerViewIsIgnored`.
4. Docs 02 (§1.3, §2.1), 03 (§6), 17 (§2.3).

### Remaining — the values (needs a phone)
`adb shell setprop log.tag.DetoxoService DEBUG`, re-bind the service,
`adb logcat -s DetoxoService:D | grep scroll`; per app record the `cls=` and
at-rest pairs for the reel pager, the comments sheet, and a caption expand;
read the pager's `viewIdResourceName` from `adb shell uiautomator dump` on the
reel screen. Then set `pagerViewId` on `ig_reel`, `yt_shorts`,
`tiktok_clips`, `snap_spotlights` in `assets/config/platforms_config.json`
(the Dart model ignores the key; `pushConfig` delivers it to native).

### Validation
- [x] `bash tool/dev.sh precommit` (incl. native tests)
- [ ] Device: with the ids set, a single-comment sheet on the allowed reel → +0
- [ ] `bash tool/qa.sh -d <serial> perf` vs baseline
