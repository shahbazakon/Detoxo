# EVO-007 — Installed-app picker (labels + icons) for manual protected-app adds

- Status: done
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/features/protected_apps + native `channels/CommandHandler.kt` (new channel method — contract change)
- Commit: 5052d20 (proposed) · implemented 2026-08-14 on the working tree above f2941b5
- Date: 2026-08-13 · Approved & implemented: 2026-08-14 (user-requested in-session)
- Effort: M

> **As built (deviations from the sketch below, all additive):** the channel method is
> named `installedApps` (not `installedAppsDetailed`), returning
> `[{package, label, icon: 96px PNG bytes?}]`, cached process-wide in
> `EngineRepositoryImpl` (in-flight-coalesced, null never cached). The picker is a
> **shared core component** (`lib/core/widgets/app_picker_sheet.dart`) used by BOTH
> Protected apps and the App Blocker — searchable, multi-select, `unavailable`-map
> reason pills, manual fallback form, refresh button. PIN gate preserved: once per
> batch when any selection is monitored. Docs 04/06/18/24 updated.

## Why
Adding a protected app requires typing a raw package id — `installedPackages`
(`CommandHandler.kt`) returns package names only, no labels or icons, so a real picker
is impossible today. Both card types on the screen render grey letter tiles
(`AppIconAvatar(iconUrl: '')`) while sibling lists (`block_app_tile.dart`) show real
icons. Package ids are undiscoverable for normal users.

## Expected user impact
"Add app" becomes one tap from a searchable list of installed apps with real names and
icons. The manual-typing dialog remains as fallback. Biggest usability gap in the
feature closed; peripheral to the intervention loop.

## Technical complexity
New channel method (e.g. `installedAppsDetailed` → `[{package, label, iconBytes}]`) —
a **platform-channel contract change** (update `channel_constants.dart`,
`engine_channel.dart`, `CommandHandler.kt`, doc 18). Icon bytes fetched on the existing
`ioExecutor`, size-capped. Dart picker sheet from `design_system` components. PIN gate
(`needsPinToAdd`) unchanged and still applies to picker selections.

## Performance impact
Off the hot path. Label+icon enumeration is heavier than the name-only query (PackageManager
icon loads); runs only when the picker opens, on the background executor, with results
paged/cached for the sheet's lifetime. No startup or per-event cost.

## Business value
The add flow is the only part of the privacy feature users actively touch; making it
effortless supports the "no willpower required" product tone (product overview). Also
retires the letter-tile inconsistency (audit UX finding).

## Rejected alternative
Bundling icons for catalog apps as assets — covers only the ~40 catalog entries (which
need no adding anyway), bloats the APK, and still leaves manual adds blind.

## Rollback
Remove the picker sheet and the channel method (additive contract — no persisted-data
changes; doc 18 entry deleted). No one-way doors.

## Implementation Plan
<!-- Fill this section ONLY once Status: approved. -->
