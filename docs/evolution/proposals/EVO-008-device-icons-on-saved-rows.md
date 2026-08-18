# EVO-008 — Show real device icons on saved Block-apps / Protected-apps rows

- Status: done
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/features/limits/app_blocker + lib/features/protected_apps (presentation only)
- Commit: implemented 2026-08-14 on the working tree above f2941b5
- Date: 2026-08-14 · Approved: 2026-08-14 ("approved all" at the evolution gate)
- Effort: S

## Why
The picker (EVO-007) shows real device icons, but saved entries still rendered grey
letter tiles (`AppIconAvatar(iconUrl: '')` in both screens' cards) — the exact
inconsistency EVO-007's business-value section called out.

## Expected user impact
Both management screens look finished: every saved row shows the app's real icon,
falling back to the letter tile for uninstalled/manual entries. Peripheral polish;
supports the product's "no shame charts" finish tone.

## Technical complexity
Dart-only, presentation-only. No channel, storage, or entity change — stored entries
still persist no icon bytes.

## Performance impact
One map lookup per row. The screens' `initState` calls
`EngineRepository.installedApps()` — which also pre-warms the process cache so the
add-picker opens instantly; the underlying native scan runs off-thread, at most once
per process (in-flight-coalesced).

## Business value
Trust/polish on the two screens users visit to manage the feature (product overview:
the feel of "it just works"). Retires the letter-tile audit finding for installed apps.

## Rejected alternative
Persisting icon bytes on the entries — duplicates the engine cache into Hive, goes
stale on app updates, and bloats storage for zero extra coverage.

## Rollback
Revert the presentation edits; no persisted-data changes.

## Implementation Plan (as built)
- Both screens' States hold `Map<String, Uint8List>? _appIcons`, filled in
  `initState` from `sl<EngineRepository>().installedApps()` (mounted-guarded).
- `AppCard` leadings pass `iconBytes: _appIcons?[packageName]` —
  `app_block_screen.dart` custom cards, `protected_apps_screen.dart`
  `_manualCard`/`_autoCard`. Letter-tile fallback unchanged.
