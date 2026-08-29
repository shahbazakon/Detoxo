# EVO-029 — Reconcile daily limits natively at the watchdog tick

- Status: done (in the working tree; stamp the commit hash on commit)
- Tier: 2 (enhancement) — changes a documented `ponytail:` ceiling
- Feature: native `engine/` + `receivers/`, mirrored in `lib/features/limits/rules`
- Commit: 190042a
- Date: 2026-09-03
- Effort: M

## Why

`lib/features/limits/rules/domain/rule_sync.dart` carries the ceiling verbatim:

```dart
/// ponytail: limits reconcile from UsageStats only while Dart runs (resume,
/// rule edit, ruleBoundary), so a spent budget can enforce late if Detoxo is
/// not opened. Upgrade path = native reconciliation at the watchdog tick via
/// UsageQuery.
```

Changing a `ponytail:` ceiling is Tier 2 by the skill's own guardrail, which is why this
is a proposal and not a fix. The audit turned up the two Tier-1 halves of the same
problem, both now fixed: the projected boundary was being discarded whenever the snapshot
had no entries (`resolve_snapshot.dart`, so a limits-only rule never armed anything at
all), and the projection re-armed itself with a period equal to the remaining budget (so
it spun as the budget approached zero). With those repaired, `ruleBoundary` works — but
only while the Dart isolate is alive. A user who sets "30 minutes of Instagram a day",
swipes Detoxo away and then opens Instagram is still unprotected until they next open
Detoxo.

That is the difference between a feature that works and a feature that works if you
remember to open the app, and it applies to two of the three rule kinds
(`TIME_LIMIT`, `OPEN_LIMIT`).

## Expected user impact

Daily time and open limits actually enforce with Detoxo closed — which is what the store
listing already promises: *"Detoxo runs quietly in the background and keeps protecting
you even when it's closed"* (`docs/info_docs/01-product-overview.md`, §Runs quietly,
always on) and *"set daily limits"* (§App & website blocking, and daily limits). Today
that sentence is true of reel blocking and the global Daily Limit, and not true of rule
limits.

## Technical complexity

Native, no new job and no new permission. The pieces already exist:

- `engine/UsageQuery.kt` already wraps `UsageStatsManager` and is JVM-tested
  (`UsageQueryTest`, 6 cases).
- `receivers/WatchdogJobService.kt` already ticks every 15 minutes and already calls
  `checkRuleBoundary`.
- `PACKAGE_USAGE_STATS` is already declared and already justified in
  `docs/code_docs/22-play-release.md:266`.

The work is a `RuleEngine`-side "spent" flip: the snapshot must carry each unspent limit's
`thresholdMs` / `maxOpens` and its package set, so native can measure them itself instead
of waiting to be told. That is a **snapshot-shape change** — a new entry kind, or new
fields on the existing entry — and therefore a wire-contract change to record in
`docs/code_docs/18-platform-channel-contracts.md` and `docs/plan_docs/09-contracts-and-storage.md`.

## Performance impact

One `UsageQuery` per 15-minute watchdog tick, on the JobScheduler thread, only when the
snapshot actually contains an unmetered limit entry (gated the way `hasReelMeter()` gates
the reel meter read today). Nothing is added to the accessibility hot path: the flip
writes into the same `@Volatile` snapshot the arms already read, so a matched event still
costs one set lookup plus a window compare. The 150 ms throttle, 1200 ms debounce,
1100 ms back cooldown and 12000-node traversal budgets are untouched.

## Business value

The highest-leverage item in this run. It closes the gap between what the listing
promises about background protection and what rule limits actually do, and it is the
difference between the rules feature being a scheduling toy and being a commitment device
— the axis the product competes on (`docs/info_docs/01-product-overview.md`, §Why Detoxo
is different: *"Easy to ignore or turn off"* vs *"keeps future-you honest"*).

## Rejected alternative

Persist the spent flag in Dart and have native read it back — i.e. keep Dart as the only
thing that ever measures usage, and just make the verdict durable across process death.
Rejected: it makes the block *sticky* rather than *correct*. A limit that was spent at
23:50 yesterday would need explicit midnight invalidation, a clock change would strand it,
and it still cannot start enforcing a limit crossed while Detoxo was closed — which is
the actual complaint. Measuring where the enforcement happens is the smaller long-term
surface, even though it is the bigger diff today.

## Rollback

Revert the native flip and the snapshot fields; Dart's resolver keeps working unchanged
because the new fields are additive and an older native build ignores them. One-way door
to note: **none** — no storage key is renamed, no manifest permission is added, and the
snapshot is re-pushed from scratch on every resume, so a downgraded build self-heals on
first open.

## Implementation Plan

### Current state

`lib/features/limits/rules/domain/usecases/resolve_snapshot.dart` — an unspent limit
contributes no entry at all; only the projected exhaustion reaches native, as a boundary:

```dart
        } else if (usageKnown && r.thresholdMs > used) {
          final remaining = r.thresholdMs - used;
          consider(
            nowMs +
                (remaining < _minProjectionMs ? _minProjectionMs : remaining),
          );
        }
```

`android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/WatchdogJobService.kt` —
`onStartJob` already calls `checkRuleBoundary(this)` inside a try/catch.

`android/app/src/main/kotlin/com/errorxperts/detoxo/engine/RuleEngine.kt` — `Entry`
carries `reelTimeLimitMs` for the global Daily Limit's meter and nothing equivalent for a
per-rule limit.

### Target state

- `SnapshotEntry` gains `usageLimitMs` (0 = none), `openLimitCount` (0 = none) and `spent`.
  A limit rule now emits an entry for today's period whether or not it has run out;
  `measuredPackages` proved unnecessary — the existing flattened `packages` is exactly the
  set to measure.
- `RuleEngine.Entry` mirrors them. **As shipped the snapshot stays fully immutable**: rather
  than a mutable `spent` field, `markSpent(ids)` rebuilds the `Snapshot` with the matching
  entries replaced by `asSpent()` copies, which also recomputes every derived gate
  (`hasPackageRules` and friends) in one swap.
- `blockingForPackage` / `blockingForHost` / `blockingForPlatform` all skip a **pending**
  entry outright, so an unspent budget blocks nothing anywhere.
- New `engine/LimitReconciler.kt` (Android-free, takes measured totals as arguments so it
  is JVM-testable exactly like `RuleEngine`): given today's per-package foreground ms and
  open counts, returns the ids that should now be spent.
- `WatchdogJobService.onStartJob` calls it, gated on the snapshot containing at least one
  unspent limit entry, feeding it `UsageQuery` results for `[todayStart, now]`.
- Dart keeps its own reconciliation: native is the backstop, Dart still re-derives on
  resume, and the snapshot re-push resets `spent` from the authoritative Dart verdict.

### Repo conventions to follow

- `RuleEngine` and the new reconciler stay Android-free — no `android.*` import — so their
  JUnit4 tests run on the JVM (`android/app/src/test/kotlin/.../RuleEngineTest.kt`,
  `ReelTrackerTest` for the style).
- The Dart snapshot writer and the Kotlin parser are a **mirror contract**: change both,
  and pin the new keys in `test/rules_engine_test.dart`'s "wire JSON carries the
  mirror-contract keys" case.
- Native prefs writes go through `ConfigStore`; the rules snapshot now lives in its own
  prefs file (`detoxo_rules_snapshot`) — keep it there.

### Steps

1. Add the three fields to `SnapshotEntry` + `toJson`; emit them for unspent limits in
   `resolveSnapshot`. Extend the mirror-contract test.
2. Mirror them in `RuleEngine.Entry` + `parse`; add `spent`, reset on `setSnapshot`.
3. Gate `blockingForPackage` on `spent` for limit entries; add `hasUnspentLimits()`.
4. New `engine/LimitReconciler.kt` + `LimitReconcilerTest.kt` (at threshold, below,
   above; opens; a package the user does not have; an empty measure set).
5. Wire it into `WatchdogJobService.onStartJob` behind `hasUnspentLimits()`, in the
   existing try/catch, using `UsageQuery` over `[todayStart, now]`.
6. Post `ruleBoundary` when a flip happens, so a live Dart resyncs and the UI agrees.
7. Update the `ponytail:` marker in `rule_sync.dart` to describe what remains (a flip is
   at most one watchdog period late), and `RuleEngine.kt`'s own 7-day marker if touched.
8. Update `docs/code_docs/18-platform-channel-contracts.md`, `27-rules-engine.md`,
   `07-daily-limit-scheduler.md`, `04-native-android-layer.md`, and
   `docs/plan_docs/09-contracts-and-storage.md`.

### Boundaries

Do NOT retune `THROTTLE_MS`, `BLOCK_DEBOUNCE_MS`, `BACK_RATE_LIMIT_MS`, `MAX_NODES`, or
the watchdog's 15-minute period. Do NOT add a job, an alarm or a manifest permission. Do
NOT make the reconciler run from the accessibility service — it is a watchdog-thread job.
Leave the global Daily Limit's `reelTimeLimitMs` meter exactly as it is; it already works.
If the code at the cited lines has drifted from the Commit stamp above, STOP and report —
do not improvise.

### Validation

- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (`LimitReconcilerTest`, JVM)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS" intact in
      wire/code, "Conscious" in UI strings
- [ ] Production readiness: snapshot + spent state survive process death and reboot via
      `BootReceiver`/`ConfigStore`; Usage Access revoked mid-day leaves an already-spent
      limit enforcing (the behaviour row 17 just established in Dart); works offline; no
      new manifest permission; Crashlytics covers the reconciler's failure path
- [ ] Native touched → manual device sanity: set a 1-minute time limit, force-stop Detoxo,
      use the target app for 2 minutes, confirm the wall appears without opening Detoxo;
      service reconnects after toggling accessibility; bubble drag/snap/tap; widget refresh
- [ ] `/docs-sync` run; mapped docs updated
