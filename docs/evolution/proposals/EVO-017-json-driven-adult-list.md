# EVO-017 — Compile the 18+ blocklist from a JSON source (scrape folded in) + block adult TLDs wholesale

- Status: done (implemented on `sensitive_protection`, commit pending — DEVICE QA OUTSTANDING)
- Tier: 2 (enhancement) — approved by the user in-session 2026-08-28 (plan approval + "Block adult TLDs wholesale")
- Feature: lib/features/limits/web_blocker (copy only) + native asset `adult_domains.txt.gz` + `tool/web_blocker/`
- Commit: fb23a68 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-28
- Effort: S

## Why
The user supplied `assets/Json/blocked_websites.json` — a 1508-row scrape of
`{name, url, redirect_url}` from an adult-site directory (252 KB, untracked, not
in `pubspec.yaml`) — and asked that the "Block adult content (18+)" toggle block
every page of every `url` and `redirect_url` in it. Recon showed:

- The 18+ block is already native and host-based: `WebBlockEngine.setAdultEnabled`
  lazily gunzips `android/app/src/main/assets/adult_domains.txt.gz` (192 hand-curated
  hosts, no source file) and `matchHost` walks the host up its parent labels
  (`WebBlockEngine.kt:62-72` at the commit above). Blocking a host blocks every page
  under it — exactly "block all the web pages".
- The scrape collapses to 57 unique hosts (`url == redirect_url` in 100% of rows;
  1311 rows are `theporndude.com/...` paths, 138 `pdude.link/...`). 21 hosts were
  already shipped, 34 were new, and 2 must never be blocked (`twitter.com`,
  `google.com` — the directory's social link and its "I am under 18 – Exit" link).
- The suffix walk ends at the bare TLD, so a line `porn` in the asset blocks every
  `*.porn` address with zero Kotlin change.

## Expected user impact
The 18+ switch now covers 226 registrable domains (every subdomain, every page)
plus every `.xxx`, `.porn`, `.sex` and `.adult` address, in any supported browser.
The Protection tile says so ("every page of 200+ known adult sites and every .xxx,
.porn, .sex or .adult address"). Peripheral to the reel loop, but it is the
"filter adult content" line of the store listing
(`docs/info_docs/01-product-overview.md`, "App & website blocking").

## Technical complexity
No Dart runtime code, no channel or storage change, no `pubspec.yaml` change.
- `tool/web_blocker/blocked_websites.json` — the human-editable SOURCE
  (`domains`, `tlds`, `allow`), moved out of `assets/` (the `pubspec.yaml:150-153`
  precedent: build-time inputs must not ship in the APK).
- `tool/web_blocker/compile_adult_list.py` + `bash tool/dev.sh adultlist` — validates
  every entry (`^(?:[a-z0-9-]+\.)*[a-z]{2,24}$`, no `www.`, nothing on `allow`) and
  writes the `.gz` byte-stably (`mtime=0`).
- `test/adult_blocklist_test.dart` — source ↔ asset drift guard + a mirror of the
  native walk (TLD entries only match as the last label; `allow` hosts never covered;
  "200+" copy pinned).
- One subtitle string in `web_protection_screen.dart`.

## Performance impact
Adult set grows 192 → 230 `HashSet` entries, loaded only on toggle-on (as before);
the per-event walk is unchanged (≤ label-count lookups). APK asset delta ≈ +0.3 KB.

## Business value
Store-listing promise made true at scale ("filter adult content"); the JSON source
lets the list be extended without touching Kotlin.

## Rejected alternative
Bundle the JSON as a Flutter asset and push its hosts through `pushWebBlocklist`:
252 KB in every APK for data Kotlin cannot read from the Flutter bundle, a
main-isolate JSON parse, and 57 more rules in the O(n) `DOMAIN` scan for data the
native engine already hashes.

## Rollback
`git checkout -- android/app/src/main/assets/adult_domains.txt.gz`, delete
`tool/web_blocker/` + `test/adult_blocklist_test.dart`, drop the `adultlist` row in
`tool/dev.sh`, restore the subtitle. No persisted data involved.

## Implementation Plan

### Current state (at the commit above)
- `android/app/src/main/assets/adult_domains.txt.gz` — 192 hosts, hand-curated,
  header "Curated; extend as needed", no source of truth.
- `lib/features/limits/web_blocker/presentation/web_protection_screen.dart:90-92` —
  subtitle `'Blocks known adult sites in any browser, on top of your own blocklist.'`.
- `assets/Json/blocked_websites.json` — the untracked scrape.

### Target state (implemented)
- `tool/web_blocker/blocked_websites.json` `{version:1, updated, tlds:[adult,porn,sex,xxx],
  domains:[226 sorted hosts], allow:[google.com, twitter.com]}`; `assets/Json/` removed.
- `tool/web_blocker/compile_adult_list.py`; `tool/dev.sh` MENU row `adultlist`.
- `adult_domains.txt.gz` regenerated: 3-line GENERATED header + 230 entries.
- `test/adult_blocklist_test.dart` (6 tests).
- Subtitle: `'Blocks every page of 200+ known adult sites and every .xxx, .porn, .sex
  or .adult address — in any browser, on top of your own blocklist.'`.

### Validation
- [x] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [x] `tool/boundaries_baseline.txt` line count unchanged (23)
- [x] New logic has a test (`test/adult_blocklist_test.dart`)
- [x] Invariants grep clean (Detoxo/errorxperts only; no `curious` leak)
- [x] Production readiness: asset restored by `onServiceConnected → reload()`; works
      offline; no manifest change
- [ ] Device QA (outstanding): with 18+ on in Chrome — `theporndude.com`, `tik.porn`,
      any `.xxx` address bounce; `google.com` / `twitter.com` load normally
- [x] `/docs-sync` run — `06`, `18`, `03`, `04`, `12`, `info_docs/02`, `info_docs/04`
