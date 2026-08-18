# EVO-012 — Per-site pause ("allow this site for a while")

- Status: done — implemented 2026-08-17; verified on-device 2026-08-18 (Realme RMX3997: 5-min pause → site loads; post-expiry probe blocked again with no app interaction — native re-arm proven. Caveat: during the paused-loads probe the service binding wasn't independently confirmed, because ColorOS repeatedly strips adb-written accessibility grants. Commit pending)
- Tier: 2 (enhancement) — approved by user in-conversation 2026-08-17
- Feature: lib/features/limits/web_blocker + native engine/WebBlockEngine.kt
- Commit: c0c5251
- Date: 2026-08-17
- Effort: M

## Why
`WebBlockEntry.pausedUntil` + the `isActive` pause branch have existed since inception
with zero UI (`web_block_entry.dart:41,62` — no code path ever sets it; audit finding).
The app-level **Pause** plan proves the pattern users want: temporary access that
re-arms itself.

## Expected user impact
"I need this one site for 15 minutes" without deleting the entry or disabling the
blocker. Auto re-arms — no way to forget, mirroring the Pause plan
(`docs/info_docs/01-product-overview.md`, "Pause").

## Technical complexity
Dart: row pause/resume action + duration sheet, cubit `pauseEntry`/`resumeEntry`,
entity `isActiveAt(now)` for testability. **Contract change:** the pushed wire entry
gains an optional `pausedUntil` (epoch ms) field; native `WebBlockEngine.Rule` reads it
and skips the rule while `System.currentTimeMillis() < pausedUntil`. Expiry is enforced
natively, so it survives process death, reboot and the app never being reopened — no
Dart timers.

## Performance impact
One `Long` compare per rule on match — negligible. Push happens only on pause/resume,
not on the hot path.

## Business value
Extends the plans-model differentiator ("flexible, not all-or-nothing") to the web
blocker. Cites product overview "Blocking plans".

## Rejected alternative
Dart-side expiry (drop paused entries from the wire + re-push on a timer): simpler wire
but fails open when the app is killed before expiry — the site would stay unblocked
until the next app launch. Native expiry is fail-safe.

## Rollback
Remove the UI + cubit methods; native ignores an absent `pausedUntil` (defaults 0), and
old wire payloads without the field parse unchanged — no one-way doors.

## Implementation Plan

### Current state
- `web_block_entry.dart:41` `pausedUntil` dead; `:62` `isActive` uses bare `DateTime.now()`.
- `web_block_sync.dart:28` skips `!e.isActive` entries entirely.
- `WebBlockEngine.kt` `Rule(pattern, type)`; `parse()` reads pattern/matchType only.
- Row trailing controls: toggle / edit (custom) / delete (`web_block_screen.dart:351-372`).

### Target state
- Entity: `bool isActiveAt(DateTime now)`; `isActive` delegates with `DateTime.now()`.
  (`blockMode` is deleted separately by approved finding 13.)
- Sync: enabled entries are always pushed; an entry with a future `pausedUntil` adds
  `'pausedUntil': ms` to its wire map. Disabled entries stay omitted.
- Native: `Rule` gains `pausedUntil: Long = 0`; `matchHost` skips a rule while
  `System.currentTimeMillis() < r.pausedUntil`.
- UI: a pause icon button on every row → `GlassBottomSheet` with duration `AppChip`s
  (5 / 15 / 30 / 60 min) → `cubit.pauseEntry(entry, duration)`. Paused rows show
  subtitle "Paused until HH:MM" and the icon flips to resume (`clearPause`).

### Repo conventions to follow
Pure logic testable via plain methods (`StreakCubit.advance` idiom); UI from
design_system components (`GlassBottomSheet`, `AppChip`); strings user-facing only.

### Steps
1. Entity: add `isActiveAt`, keep `clearPause` (now used).
2. Sync: emit `pausedUntil` for future-paused enabled entries.
3. `WebBlockEngine.kt`: parse + honor `pausedUntil`.
4. Cubit: `pauseEntry` / `resumeEntry` via `_commit`.
5. Screen: pause/resume button + duration sheet + paused subtitle.
6. Tests: `isActiveAt` branches; sync emits `pausedUntil`; cubit pause/resume round-trip.

### Boundaries
No new storage keys (field already persisted). No timers. If cited lines drifted from
c0c5251, stop and report.

### Validation
- [ ] `bash tool/dev.sh precommit`
- [ ] Manual device: pause a blocked site → loads; after expiry → blocked again without
      opening Detoxo
- [ ] `/docs-sync`
