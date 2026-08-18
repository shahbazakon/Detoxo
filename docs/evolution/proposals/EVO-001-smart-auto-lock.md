# EVO-001 — Add Smart Auto Lock to the PIN lock

- Status: done (implemented at `d0ab47e` + this change set)
- Tier: 2 (enhancement) — explicitly requested and approved by the user in
  conversation (plan approval, 2026-08-07)
- Feature: `lib/features/access_protection` + native `MainActivity.kt` /
  `channels/CommandHandler.kt`
- Commit: d0ab47e (base at proposal time)
- Date: 2026-08-07
- Effort: M

## Why

The PIN lock only gated cold starts (`lib/app/splash_screen.dart` launch gate)
and explicit `requirePin` actions. Returning from the background — the common
path — never re-asked for the PIN, and the app's content stayed readable in the
Recents switcher. For a commitment device, the cheapest bypass was "just don't
kill the app."

## Expected user impact

The lock now behaves like a real app locker: re-locks on resume per a chosen
timeout (never / immediately / 15 s / 30 s / 1 m / 5 m / when the screen turns
off), optionally blanks the Recents preview and blocks screenshots, and the
unlock sheet honestly offers fingerprint **or device credential**. Strengthens
the "optional PIN lock keeps future-you honest" differentiator row in
`docs/info_docs/01-product-overview.md`.

## Technical complexity

Dart: `PinConfig` fields (`autoLock`, `secureScreen`), `AutoLockPolicy`,
`PinAutoRelock` root-navigator observer, setup-screen UI. Native: FLAG_SECURE
toggle + `ACTION_SCREEN_OFF` timestamp. Two new channel commands
(`setSecureScreen`, `lastScreenOff`) — contract additions, documented in
code_doc 18's source (`channel_constants.dart`).

## Performance impact

None on the accessibility hot path: everything runs on app lifecycle
transitions and screen taps. One extra channel round-trip on resume only when
the `screenOff` option is selected.

## Business value

Directly reinforces the store-listing "Make it stick" claim (PIN +
uninstall protection). Recents privacy is a table-stakes feature of competing
app lockers.

## Rejected alternative

A lock **overlay** via `MaterialApp.builder` — rejected because the builder
child *is* the Router: no Navigator ancestor there, so dialogs/sheets inside
the lock screen crash and system back keeps driving the router underneath.
A root-navigator route push (the existing `requirePin` idiom) needs none of
that plumbing.

## Rollback

Revert the change set. `autoLock`/`secureScreen` are additive JSON keys —
older builds ignore them on load (`fromJson` defaults), so no storage
migration and no one-way doors. No new manifest permission.

## Implementation Plan

Executed as planned; see the commit touching:
`pin_config.dart`, `pin_repository{,_impl}.dart`, `injector.dart`,
`channel_constants.dart`, `engine_channel.dart`, `CommandHandler.kt`,
`MainActivity.kt`, `pin_cubit.dart`, `pin_lock_screen.dart`,
`pin_auto_relock.dart` (new), `main.dart`, `pin_setup_screen.dart`,
`test/access_protection_test.dart` (+23 tests),
`integration_test/pin_setup_flow_test.dart`.

Validation: `bash tool/dev.sh precommit` green; manual device list in
`docs/code_docs/08-pin-lock-recovery.md` §Auto lock.
