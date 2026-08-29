# EVO-050 — Render the duration chips on the wall itself

- Status: approved
- Tier: 2 (enhancement)
- Feature: `android/.../overlay/BlockScreenOverlay.kt`, `lib/features/limits/unblock`
- Commit: 190042a
- Date: 2026-09-06
- Effort: M

## Why

"Allow for a while" is the one M8 affordance the user reaches at the moment of temptation,
and it is the one that leaves the moment. Today the tap:

1. writes `ConfigStore.setPendingUnblock(type, id, now)`
   (`overlay/BlockScreenOverlay.kt:280`),
2. `detach()`es the wall and `launchDetoxo(context)` — which swallows its own failure
   (`overlay/OverlayWindows.kt:31`),
3. waits for `bootstrap`/`AppResumeSync` to drain `takePendingUnblock`,
4. waits for the app gate (splash, onboarding, **PIN**) before
   `PendingUnblockListener` may open the sheet,
5. finally shows four chips.

Four steps of state carried across a process boundary to ask one question with four
answers. The `ponytail:` marker on that hand-off already names this as the upgrade path,
and every defect M8's own audit found on this path — a key with no TTL that re-fired days
later, a tap eaten by a PIN-locked launch, a sheet with no Navigator above it — exists only
because the question is asked somewhere other than where it was raised.

## Expected user impact

The wall gains a second row: **5 / 15 / 30 / 60**. One tap, no app switch, no PIN, no
launch. The user stays in the app they were in, which is the entire premise of
`01-product-overview.md` ("Steps in **while** you're scrolling" / "You stay in the app you
opened for a reason").

It also removes the strangest thing about the current flow: pressing a button on a wall
that is blocking Instagram takes you *out of Instagram and into Detoxo*, which is the
outcome the wall was already trying to produce.

## Technical complexity

The largest of the four M8 follow-ups, and the only one that touches native rendering.

- `overlay/BlockScreenRenderer.kt` already builds every wall button and sets
  `contentDescription` and a 48 dp minimum on each (the M7 nudge card was fixed to match),
  so a chip row is the existing button builder in a `LinearLayout`.
- **New channel command** `grantTemporaryUnblock {targetType, targetId, minutes}` —
  a contract change, and the first native→Dart *request* on this feature. It is a command,
  not an event, so it is dropped if Dart is not running; native therefore writes the grant
  to `ConfigStore.temporaryUnblocksJson` itself and Dart reconciles on next resume.
- That is the real cost: native gains **write** access to the grant list, which today it
  only ever reads (`UnblockRegistry.setGrants`). The store becomes bidirectional, and
  `syncTemporaryUnblocks`'s "Dart is the only writer" assumption
  (`unblock_sync.dart:12`) stops holding.

`pendingUnblock` and its TTL stay as the fallback for the case where the overlay cannot
render chips (no `SYSTEM_ALERT_WINDOW`, toast fallback).

## Performance impact

None on the accessibility hot path — this is wall-render time, already behind
`BLOCK_DEBOUNCE_MS`. Four extra views on a screen that already builds three buttons.

## Business value

Highest impact of the four on the differentiator itself: it converts M8 from "a setting you
go and change" into "a decision you make in the moment", which is the sentence the whole
product is sold on (`01-product-overview.md`, "The solution").

## Rejected alternative

Keep the app switch but pre-warm the sheet — drain `pendingUnblock` before the gate and
render the sheet over the PIN screen. Lost outright: it puts a bypass affordance above the
lock screen that guards settings, which inverts `access_protection`'s contract. The PIN
must never be the thing standing between the user and *more* protection, but it also must
not be bypassable by a wall.

## Rollback

Ship the chip row behind the same `offersUnblock` payload flag it already keys on; setting
it false everywhere restores the current behaviour. The one-way door is the **new command**
and native's new write to `temporary_unblocks_json` — reverting after release means Dart
must still tolerate a natively-written list, which it does (it re-reads and re-pushes on
resume). No storage-key rename, no permission.

## Implementation Plan

### Current state

```kotlin
// overlay/BlockScreenOverlay.kt — the whole action today
BlockScreenRenderer.ACTION_UNBLOCK -> {
    if (!preview && p.referenceId.isNotEmpty()) {
        storeFor(context).setPendingUnblock(p.referenceType, p.referenceId, System.currentTimeMillis())
    }
    detach(); launchDetoxo(context)
}
```

### Target state

- `ACTION_UNBLOCK` expands an inline chip row instead of detaching.
- A chip tap appends a grant to `ConfigStore.temporaryUnblocksJson`, calls
  `service.refreshTemporaryUnblocks()`, `detach()`es, and posts `blockScreenAction` so a
  live Dart isolate can reconcile immediately.
- Dart's `AppResumeSync` reconciles the native-written list into Hive on next resume,
  keeping Hive authoritative for history.
- `preview` never writes (the style editor's sample wall must not arm a real unblock).

### Verification

- `UnblockRegistryTest.kt`: a natively appended grant parses and expires identically.
- Dart: `syncTemporaryUnblocks` merges a natively-written row instead of overwriting it.
- Device sanity (native, not judgeable from source): chip row renders at 1.3× text scale;
  TalkBack announces each chip; the wall dismisses on grant; the grant survives force-stop.
- `bash tool/dev.sh precommit`, then `/docs-sync`: `31` §5, `25`, `18` (new command), `09`.
