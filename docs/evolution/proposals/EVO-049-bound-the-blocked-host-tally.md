# EVO-049 — Bound the blocked-host tally

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/limits/web_blocker/data/repositories/web_block_stats_repository_impl.dart`
- Commit: 190042a
- Date: 2026-09-04
- Effort: S

## Why

The web-block stats blob keeps a per-host tally so the dashboard can show "Most
blocked". It only ever grows. `web_block_stats_repository_impl.dart:38-41`:

```dart
final hosts = Map<String, dynamic>.from(data['hosts'] as Map);
hosts[host] = ((hosts[host] as int?) ?? 0) + 1;
data['hosts'] = hosts;
```

`_rollDate` (`:75-81`) resets `today` and never touches `hosts`. Nothing else in
the repo writes, prunes or clears `StoreKeys.webBlockStats` — the only path that
removes it is a full `LocalStore.clearAll()` ("Reset app data").

Two consequences:

1. **Unbounded growth.** Matching is suffix-based (`WebBlockEngine.kt:65`
   `host == r.pattern || isSubdomainOf(host, r.pattern)`), and native reports the
   **observed** host, not the matched pattern
   (`DetoxoAccessibilityService.kt:1002`). So one `google.com` rule accumulates a
   separate key for every distinct subdomain visited. Every `webBlocked` event
   then pays a full `jsonDecode` → map copy → O(hosts) top-host scan →
   `jsonEncode` → write, over a map that never shrinks.
2. **Retention.** That blob is a permanent, plaintext, on-device list of hosts
   the user tried to reach, with no expiry and no user-facing way to clear it.
   Adult-list hits are already excluded (EVO-018) and nothing leaves the device,
   but the native side is deliberately bounded to three counters
   (`ConfigStore.kt` `KEY_WEB_BLOCK_DATE/TODAY/TOTAL`) — the Dart mirror is the
   only place an unbounded history accrues.

## Expected user impact

Invisible in normal use: "Most blocked" keeps naming the right host, because the
cap evicts the *least*-blocked entries. What goes away is an ever-growing write
on the block path and an indefinite browsing-history residue. Peripheral to the
intervention loop — this is hygiene, not a feature.

## Technical complexity

One file, Dart only. No wire change, no new storage key. The blob's shape is
unchanged, so old and new builds read each other's data; an oversized existing
map is trimmed the first time it is written.

## Performance impact

Improves the per-event cost, which is the point: the map is capped, so the
`_toStats` scan and the JSON encode are bounded instead of growing with usage.
The trim itself is an O(n log n) sort that runs only on the write that exceeds
the cap.

## Business value

Backs the privacy posture the FAQs already state (`info_docs/04-faqs.md` — blocks
are counted, adult hosts never named, nothing leaves the device). "We keep a
capped tally, not a browsing history" is a defensible sentence; the current
behaviour is not.

## Rejected alternative

**Store only the top host and its count, dropping the map entirely.** Smallest
possible footprint and the strongest privacy answer. Rejected because "most
blocked" would then be unrecoverable if that one host is later unblocked or
paused — the ranking needs runners-up to fall back on. A cap keeps the feature
honest at a fixed, small cost.

## Rollback

Delete `_maxTrackedHosts` and the trim call. Any already-trimmed data stays
valid — the blob shape never changed — so a revert loses nothing but the bound.

## Implementation Plan

### Current state

As quoted above: `:38-41` grows the map, `:48` writes it, `_sanitiseHosts`
(added in the same pass as the Tier-1 stream-killer fix) coerces it on read.

### Target state

A `_maxTrackedHosts = 50` cap applied on write. When the map exceeds it, keep the
50 highest counts and drop the rest — the tail is by definition not "most
blocked". The trim lives beside `_sanitiseHosts`, so read-coercion and
write-bounding sit together.

### Repo conventions to follow

Private static helper on the repository impl, documented with the reason rather
than the mechanism — matching the file's existing comment style (`:43-44`,
`:57-58`).

### Steps

1. Add `_maxTrackedHosts` and a `_trimHosts` helper.
2. Call it in `watch()` immediately before `_store.write`.
3. Test: a map over the cap keeps the top entries and drops the smallest, and the
   surviving `mostBlockedHost` is unchanged.

### Boundaries

Do not change the blob's JSON shape or `StoreKeys.webBlockStats`. Do not touch
the native counters — `today`/`total` are engine-supplied and authoritative. If
the code at the cited lines has drifted from commit 190042a, STOP and report.

### Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] New logic has a test in the repo pattern
- [ ] Production readiness: survives process death (plain store write), works
      offline, no new permission
- [ ] `/docs-sync` — `06` and `09-persistence-data-model.md`
