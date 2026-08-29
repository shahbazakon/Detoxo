# EVO-021 — Back off the stage-3 DFS on counting-pass misses

- Status: done (implemented on `sensitive_protection`, commit pending —
  device confirmation outstanding, see Validation)
- Tier: 2 (enhancement) — approved by the user in-session ("i approved all",
  2026-08-29)
- Feature: content_counter (native `accessibility/DetoxoAccessibilityService.kt`
  counting pass), `engine/DetectionConfig.kt`
- Commit: 424a8f6 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-29
- Effort: S + a calibration check

## Why
`matches()` runs three stages cheapest-first: the event source, then
`root.findAccessibilityNodeInfosByViewId(id)` (stage 2 — the framework resolves
the id through the app's own `Resources` and walks its real View tree for it),
then a bounded DFS of up to `MAX_NODES = 12000` nodes over binder (stage 3).
On every **miss** all three run. The counting pass (`countContent`) checks the
window at `COUNT_THROTTLE_MS = 400` whenever a monitored app emits events, and on
a non-reel screen — the feed, DMs, a profile — every one of those checks is a
miss, i.e. a full stage-3 walk of the same window against the same ids stage 2
just searched, 2.5 times a second, for as long as the user browses. With blocking
off (or the platform disabled for blocking) the counting pass is the only walker,
so this was the single largest per-event cost of the "always on" counter.

## Expected user impact
Less battery spent while browsing feeds — the hours users spend *not* on reels —
which feeds the OEM force-stop cycle EVO-016 targeted. No change to what is
counted on any app whose reel surface is a real View with a resolvable id (every
catalogued detector today). Reel-entry latency for the bubble is unchanged on
those apps (stage 2 still runs every check).

## Technical complexity
Native only; no channel, storage or config-schema change.

- `DetectorRule.qualifiedIds` — the fully-qualified id list is built once at
  config parse (`DetectionConfig.parsePlatform(p, pkg)`) instead of a `map` per
  `matches()` call.
- `matches(root, event, detector, deep = true)` — `deep = false` returns after
  stage 2. Such a result is partial and is **never memoised**: the block pass
  (which never backs off) still calls `matchesMemo` and gets a full answer.
- `countContent`: a per-package consecutive-miss counter `countMisses` cycling
  `0..DFS_SKIP` (`DFS_SKIP = 4`). The DFS runs only at 0 — i.e. at most every
  5th check (2 s) on a non-reel screen. Any hit and every
  `TYPE_WINDOW_STATE_CHANGED` reset it to 0, so a window change always checks
  deep.

Ceiling (`ponytail:` in the code): a surface that only the DFS can find — an id
the app's own `Resources` cannot resolve (split / dynamic-feature module ids) —
is seen up to `DFS_SKIP` checks (≤ 2 s) late, and a transient deep miss on it
can end the reel session. No catalogued detector is known to be in that class;
the device check below confirms.

## Performance impact
Non-reel screens with blocking off: stage-3 walks drop from 2.5/s to 0.5/s
(−80 %). Reel screens: unchanged (a hit resets the counter; every check on a hit
streak is deep and short-circuits at stage 1/2 anyway). Block path: unchanged
(Guardrail 8 — `THROTTLE_MS`, `MAX_NODES` untouched). One `HashMap` read/write
per counting check.

## Business value
`docs/info_docs/01-product-overview.md` — "runs quietly, always on": the
counter is on by default for every user, so its idle cost is the product's idle
cost.

## Rejected alternative
Skip stage 3 entirely on the counting pass for `FINDBYID` / `VIEWID_RES_NAME`
detectors (stage 2 authoritative). Cheaper still, but it makes the counter blind
to the split-module-id class forever instead of ≤ 2 s late, with no device data
to prove the class is empty. The bounded back-off keeps the DFS as a periodic
safety net at 20 % of its old cost.

Also rejected: resetting the back-off on pager-signature scrolls
(`settledPage ≥ 0`) — a feed shows 1–2 posts per screen and reports `(n, n+1)`
too, so every feed scroll would have reset it.

## Rollback
Revert the `countContent` / `matches` edits and drop `DetectorRule.qualifiedIds`
(restore the per-call `map`). No data involved.

## Implementation Plan (as shipped)

### Steps
1. `engine/DetectionConfig.kt` — `DetectorRule.qualifiedIds`; `parsePlatform`
   takes the package and prefixes `FINDBYID` ids.
2. `accessibility/DetoxoAccessibilityService.kt` — `matches(..., deep)`,
   `matchesMemo` without the `pkg` param, `countMisses` + `DFS_SKIP`, the
   window-change reset, shallow calls bypass the memo.
3. Docs 03 (§3, §4, §6, §8), 04, 17 (§2.1).

### Validation
- [x] `bash tool/dev.sh precommit` passes
- [x] Native tests green (ReelTracker unaffected)
- [ ] **Device check (calibration session, with the EVO-020 checklist):** with
      the bubble on, browse the Instagram / YouTube feed for ≥ 5 s, then open a
      reel **by tap** (no scroll). The bubble must appear within ~400 ms; if it
      takes ~2 s, that app's reel id is stage-2-blind and needs a note in
      `platforms_config.json` (or the rejected-alternative trade-off revisited).
- [ ] `bash tool/qa.sh -d <serial> perf` vs baseline: fewer walks, no regression.
