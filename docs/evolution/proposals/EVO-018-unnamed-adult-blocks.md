# EVO-018 — Count adult-list blocks without naming the host

- Status: done (implemented on `sensitive_protection`, commit pending — DEVICE QA OUTSTANDING)
- Tier: 2 (enhancement; `webBlocked` contract change) — approved by the user in-session 2026-08-28 ("Never name adult hosts")
- Feature: web_blocker (native `engine/WebBlockEngine.kt`, `accessibility/DetoxoAccessibilityService.kt`, `res/values/strings.xml`)
- Commit: fb23a68 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-28
- Effort: S

## Why
Every web block posted `{host, mode, today, total}`; Dart tallied the host in
plaintext Hive (`web_block_stats_repository_impl.dart:36-40`) and rendered the
top one in bold as "Most blocked" (`web_block_screen.dart:196-203`), and the
native toast named it too (`DetoxoAccessibilityService.kt:585`). With the 18+
list on, that is an adult domain on screen for anyone glancing at the phone —
contradicting the repo's own stance two lines away ("Never log the host",
`native_event_reporter.dart:55` "browsing targets are private"). EVO-017 made
adult hits far more likely.

## Expected user impact
Adult-list blocks still count ("Blocked today" / "Total blocked" / focus minutes)
but are never named: the toast reads "Adult site blocked by Detoxo", and no adult
domain can appear in the "Most blocked" line or the persisted host tally. The
user's own blocklist hits stay attributable ("youtube.com is blocked by Detoxo").

## Technical complexity
Native-only. `WebBlockEngine.matchHost` returns `Match.RULE | Match.ADULT | null`
instead of a boolean (single caller). `handleBrowser` builds the `webBlocked`
payload with `source` and omits `host` for ADULT; new string
`toast_blocked_adult`. **Contract change:** `webBlocked` = `{source, mode, today,
total, host?}` — Dart already tolerated a missing host
(`(e['host'] as String?)?.trim()` guard), so no Dart runtime change; the doc
comment on `ChannelEvents.webBlocked` and docs 03/06/18 updated.

## Performance impact
None on the hot path beyond one enum compare; the payload map is built only on a
block (≤ 1 per 1.2 s).

## Business value
Privacy is a stated differentiator ("Your counts and settings stay on your
device", product overview). An adult domain rendered on the blocker screen is
the kind of thing that ends up in a 1-star review.

## Rejected alternative
Dart-side filtering against the user's saved entries: it would also un-name
popular-site aliases and app-derived domains (which are never stored as entries),
and Dart cannot tell an adult hit from a rule hit without the native `source`.

## Rollback
Revert the three native files + the `channel_constants.dart` comment. Dart keeps
working either way (it never required `source`).

## Implementation Plan

### Current state (at the commit above)
- `WebBlockEngine.kt:49-74` — `fun matchHost(...): Boolean`.
- `DetoxoAccessibilityService.kt:564-586` — `if (!webEngine.matchHost(host))`,
  `mapOf("host" to host, "mode" to "PRESS_BACK", ...)`, `getString(R.string.toast_blocked, host)`.

### Target state (implemented)
- `enum class Match { RULE, ADULT }`; `matchHost` returns `Match?`.
- `handleBrowser`: `val adult = match == WebBlockEngine.Match.ADULT`; payload
  `source`/`mode`/`today`/`total` + `host` only when `!adult`; toast
  `toast_blocked_adult` for adult hits.
- `strings.xml`: `<string name="toast_blocked_adult">Adult site blocked by Detoxo</string>`.
- Test: `test/web_blocker_test.dart` "an adult-list block counts but is never named".

### Validation
- [x] `bash tool/dev.sh precommit` passes
- [x] Test added in the repo pattern
- [x] Invariants grep clean
- [ ] Device QA (outstanding): adult host → toast "Adult site blocked by Detoxo", stats
      count up, "Most blocked" stays empty; custom-blocklist host → toast still names it
- [x] `/docs-sync` run — `03`, `04`, `06`, `18`, `info_docs/02`, `info_docs/04`
