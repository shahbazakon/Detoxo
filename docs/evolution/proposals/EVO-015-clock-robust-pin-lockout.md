# EVO-015 — Anchor the PIN lockout to the monotonic clock

- Status: done (implemented on `sensitive_protection`, commit pending)
- Tier: 2 (enhancement) — approved by the user in-session ("I approved all", 2026-08-27)
- Feature: lib/features/access_protection + native channel
- Commit: fb23a68 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-27 (revised 2026-08-28 after adversarial review)
- Effort: M

## Why
`pin_config.dart` computed `isLockedOut` purely from the wall clock
(`lockedUntil!.isAfter(DateTime.now())`), set from `DateTime.now().add(lockout)`
in `pin_cubit.dart`. Moving the Settings clock forward cleared the entire
escalating ladder (up to 24 h). In a self-control app the "attacker" is the
user's impulsive self — a clock bump is the first bypass they will find.
Notably `PinCubit.matches` two lines away was already clock-injected; the
lockout path was not. Distinct from EVO-002/003/004.

## Design (as shipped, post-review)
The first cut anchored the lockout to `elapsedRealtime` alone and inferred
"same boot" from `nowElapsed >= anchor`. Adversarial review broke it three
ways: the heuristic re-arms stale windows on a LATER boot once uptime passes
the old anchor; a forward clock jump left the keypad enabled while `verify`
refused the CORRECT PIN as "Incorrect PIN"; a backward jump froze the keypad
for wall-time that never really passed. The shipped design fixes the root:

1. **Boot identity, not a heuristic.** The channel method `monotonicNow`
   returns `{elapsedMs: SystemClock.elapsedRealtime(), bootCount:
   Settings.Global.BOOT_COUNT}` (BOOT_COUNT exists since API 24 = minSdk).
   `PinConfig` persists `lockoutElapsedUntilMs` + `lockoutBootCount`; the
   monotonic leg is trusted only while the live boot count matches — sound in
   both directions, cross-boot readings are simply invalid (wall clock
   governs).
2. **One authority, reconciled into the display.** `PinConfig.
   lockoutRemainingAt(now, {elapsedMs, bootCount})` is the single truth
   (monotonic when valid, wall otherwise). `PinCubit.reconcileLockout()` —
   called from `load()`, on lock-screen entry (`pin_lock_screen.dart`
   initState) and inside `verify()` — realigns the persisted `lockedUntil` to
   `now + remaining` when it drifts >2s, and clears expired lockouts. The
   lock screen keeps its cheap wall-clock rendering, but the stamp it renders
   is continuously re-synced to the monotonic truth, so display and
   enforcement cannot split: a forward jump re-shows the countdown (no more
   "Incorrect PIN" on the correct PIN), a backward jump releases the keypad
   after the true remaining time.

## Expected user impact
The friction feature holds under its obvious bypass, and clock corrections
(NTP, timezone fixes) can neither hide a lockout nor extend one.

## Technical complexity
New channel method `monotonicNow` (map payload, see doc 18); two additive
JSON keys on the persisted `PinConfig` (`lockoutElapsedUntilMs`,
`lockoutBootCount` — legacy configs parse unchanged); `PinRepository.
monotonicNow()`; reconcile logic pure + `@visibleForTesting`
(`PinCubit.reconciled`).

## Performance impact
One channel round-trip per `verify()`/lock-screen entry, and on `load()` only
when a lockout is actually persisted (early-return otherwise) — nothing on
the accessibility hot path.

## Business value
Strengthens the commitment device that keeps the intervention loop binding
(product overview: friction the user cannot trivially undo in the moment).

## Rejected alternatives
- Clock-rollback detection only (refuse when device time < last-seen) —
  misses forward jumps, false-positives on timezone travel.
- `elapsedRealtime`-only with a `>= anchor` same-boot heuristic (first cut) —
  unsound across boots; killed by review.

## Rollback
Revert the entity/cubit/channel edits. The two JSON keys are additive and
ignored by older code — no migration or one-way door.

## Known ceiling
ponytail: a reboot invalidates the monotonic leg, so reboot + clock-forward
together still clear a lockout — the wall leg is all that survives a reboot.
Accepted; closing it needs a trusted time source the device doesn't have
offline. A clock changed while the lock screen is already open reconciles on
the next entry/verify, not live.

## Validation
`test/access_protection_test.dart`: monotonic-anchored forward-jump refusal
with display realignment via `load()`; backward-jump release; stale
cross-boot window can never re-arm (the review's boot-B scenario); reboot
with wall time remaining stays locked; off-Android wall fallback; legacy
JSON round-trip.
