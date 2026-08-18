# EVO-010 — Refresh affordance in the add-app picker

- Status: done
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/core/widgets/app_picker_sheet.dart (+ both consumer screens)
- Commit: implemented 2026-08-14 on the working tree above f2941b5
- Date: 2026-08-14 · Approved: 2026-08-14 ("approved all" at the evolution gate)
- Effort: S

## Why
The installed-apps cache is process-lifetime by design (docs 18): an app installed
mid-session never appears in the picker, with no escape short of restarting Detoxo.
The `refresh:` parameter existed on `EngineRepository.installedApps` but nothing
exposed it.

## Expected user impact
A refresh button beside the picker's search field rescans on demand. Rare need, but
total when hit ("I just installed it, where is it?"). Peripheral to the loop.

## Technical complexity
Dart-only. Optional `refreshApps` callback on `showAppPickerSheet`; screens pass
`() => sl<EngineRepository>().installedApps(refresh: true)`. A failed rescan keeps
the currently shown list (repo also serves stale on failure — never a blank picker).

## Performance impact
User-initiated only; the rescan runs on the existing native `ioExecutor`, disabled
while a load is in flight.

## Business value
Removes a dead-end papercut from the add flow; no store-listing story.

## Rejected alternative
Pull-to-refresh — fights the modal bottom sheet's drag-to-dismiss gesture (both are
vertical drags on the same surface); a button has no gesture ambiguity.
(Auto-invalidation via `ACTION_PACKAGE_ADDED` receivers was also considered: modern
Android restricts implicit package broadcasts to runtime-registered receivers, which
would couple the always-on service to a picker concern — rejected as disproportionate.)

## Rollback
Remove the button + parameter; no persisted data.

## Implementation Plan (as built)
- `showAppPickerSheet(..., refreshApps: ...)` optional param; `_AppPickerBody._run()`
  drives both initial load and rescans; refresh `IconButton` (tooltip "Refresh app
  list") renders only when the callback is provided, disabled while `_loading`.
- Test: `test/app_picker_test.dart` "refresh button rescans and updates the list".
