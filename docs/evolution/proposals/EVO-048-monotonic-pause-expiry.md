# EVO-048 — Anchor per-site pause expiry to the monotonic clock

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: native `engine/WebBlockEngine.kt`
- Commit: 190042a
- Date: 2026-09-04
- Effort: S

## Why

EVO-012 gave each blocklist entry a pause window that native enforces, so it
re-arms even if the Flutter app never runs again. Expiry is read off the **wall
clock** — `WebBlockEngine.kt:59-61`:

```kotlin
val now = System.currentTimeMillis()
for (r in rules) {
    if (now < r.pausedUntil) continue // per-site pause window
```

`pausedUntil` is an absolute epoch stamp pushed from Dart
(`web_block_sync.dart:55`). Rolling the device clock backwards in Settings holds
a 5-minute pause open for as long as the user likes — a two-tap bypass of the
blocklist, from inside Android's own Settings, with no PIN.

The repo already solved exactly this attack for the PIN lockout and documented
why, at `CommandHandler.kt:376-381`:

> Monotonic clocks: the PIN lockout anchor a Settings clock change cannot move;
> BOOT_COUNT makes a cross-boot reading detectable (`elapsedRealtime` alone
> restarts at 0 and is ambiguous).

The web pause never adopted it.

## Expected user impact

None visible when the clock is left alone: a 30-minute pause still lasts 30
minutes. What changes is that it *can't be extended by lying to the device*.
This is the same intervention-loop integrity argument as EVO-030 (strict rules a
Pause cannot lift): a limit the user can trivially void is decoration.

## Technical complexity

Native only, inside one class. **No wire change** — Dart keeps sending the
absolute `pausedUntil`, and native converts it to a monotonic deadline at parse
time. No storage-schema change: the persisted blocklist JSON is untouched, so a
downgrade keeps working.

## Performance impact

Strictly cheaper on the hot path: `SystemClock.elapsedRealtime()` is a
`clock_gettime` on a vDSO page, versus `System.currentTimeMillis()`, and the
conversion happens once per push/reconnect in `parse()`, not per event.

## Business value

Protects the per-site pause, a paid-tier-adjacent convenience that only works if
it is trustworthy (`docs/info_docs/01-product-overview.md` — honest enforcement).

## Rejected alternative

**Send a duration instead of an absolute stamp from Dart.** Cleaner in principle
— the wire would carry `pauseMs` and native would own the deadline entirely.
Rejected because it is a breaking wire change for a bypass that can be closed
without one, and `pausedUntil` is also what the UI renders ("Paused until 5:30
PM"), so Dart needs the absolute value anyway.

## Rollback

Restore the two lines: `pausedUntil` back onto `Rule`, and the
`now < r.pausedUntil` comparison. Nothing persisted changes, so a revert is
immediate and needs no migration.

### Residual risk, stated plainly

`elapsedRealtime()` restarts at 0 on reboot, so `parse()` re-derives the deadline
from the wall clock every time the blocklist is (re)pushed — including on service
reconnect after a boot. A user who sets the clock back **and then reboots** still
extends the pause. Closing that too needs the `BOOT_COUNT` half of the PIN
idiom and a persisted anchor; it is not worth the schema change for a
per-site pause, and this proposal deliberately stops short of it.

## Implementation Plan

### Current state

`android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt:24-29`

```kotlin
private data class Rule(
    val pattern: String,
    val type: String,
    val pausedUntil: Long = 0L,
    val regex: Regex? = null,
)
```

`:59-61` as quoted above; `:99` parses `o.optLong("pausedUntil", 0L)`.

### Target state

`Rule.pausedUntilElapsed` holds a `SystemClock.elapsedRealtime()`-based deadline
(0 = not paused). `parse()` converts the pushed wall-clock stamp once:
remaining = `pausedUntilWall - System.currentTimeMillis()`; a non-positive
remaining means the pause already expired and the rule is simply active.
`matchHost` compares against `SystemClock.elapsedRealtime()` and no longer reads
the wall clock at all.

### Steps

1. Rename the `Rule` field and add the conversion in `parse()`.
2. Swap the comparison in `matchHost()`; drop the now-unused `now` local.
3. Update the KDoc on `Rule` and the doc table in `06-app-and-web-blocker.md`.

### Boundaries

Do not change the wire payload or `web_block_sync.dart`. Do not touch
`RuleEngine`'s own time handling. If the code at the cited lines has drifted from
commit 190042a, STOP and report.

### Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] Native JVM tests still pass
- [ ] Production readiness: pause still survives process death and reboot via the
      persisted blocklist; no new permission; works offline
- [ ] Manual device check: set a 5-minute pause, roll the clock back an hour,
      confirm the site is still blocked after the 5 minutes elapse
- [ ] `/docs-sync` — `06`
