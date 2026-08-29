# M3 — Rules engine: schedules, daily time limits, open limits

- Status: **shipped (lean core)** — engineering doc [`code_docs/27-rules-engine.md`](../code_docs/27-rules-engine.md); on branch `sensitive_protection` (commit pending at the time of writing).
- Shipped with these deviations from the plan below (each decided against the real code, see the engineering doc): the wire snapshot is **one entry per rule with nested absolute `windows: [[fromMs, untilMs]]` resolved 7 days ahead** (not a flat `activeFromMs/activeUntilMs`), plus `always` and `reelTimeLimitMs`; **the global Daily Limit is enforced through a synthetic `daily_reel_limit` snapshot entry metered natively by `ContentCounter.timeTodayMs()`** — `DailyLimitCubit` and its screen are not migrated, they stay the ring's source; rule blocks sit **below the Pause gate** (a Pause lifts them like reel/web blocking; App Blocker locks stay above, unchanged — the M2.2 ordering question is answered here); `ALL_EXCEPT` inverts membership **only within a listed dimension** (an empty list targets nothing) and the editor emits `BLOCK` only; time / open limits target apps + categories and are **reconciled in Dart from UsageStats** whenever Dart runs (resume, edit, `ruleBoundary`, a one-shot timer) — native never counts minutes, so a spent budget can enforce late; the push path is owned by the app-wide `RulesCubit` (no `syncEngineBlocklists` leg); no `monitored` set, no stored limit state, no `timezoneId` (device zone), no `deleteAfterMs`, no `usageLimitReached` event (the `blocked` event gained `reason`); **deferred**: boundary notifications (`flutter_local_notifications` stays unwired), snooze, `DATE_INTERVAL`, `FIXED_DURATION`, and `ALL_EXCEPT` in the editor — all additive to the stored document; `testImplementation("org.json:json")` was added so `RuleEngine.parse` runs on the JVM; `docs/suggestion_docs/` does not exist in this repo, so the source links below are dead.
- Source: [B2 Rules Engine](../suggestion_docs/flutter-migration/B-blocking/B2-rules-engine.md) · [E1](../suggestion_docs/flutter-migration/E-platform-growth/E1-notifications-scheduling.md) for the supersede convention
- Feature areas: new `lib/features/limits/rules/`, native `engine/RuleEngine.kt`
- Effort: **L** (the largest milestone: new domain, new wire shape, a native evaluator, a boundary clock)
- Blocked by: M0 · Blocks: M5, M6

The milestone that most changes what the product can do, and the one with the most edge cases. The
algorithm below is carried close to verbatim because its edge cases *are* its value.

## Why now

**No schedule exists anywhere in Detoxo.** Every blocking primitive today is global and untimed:

| Primitive | Scope | Time behaviour |
|---|---|---|
| Plan (Block All / Conscious / One Reel / Unblock) | global | none — sticky until changed |
| Pause | global | 2–10 min, then auto-revert |
| App Blocker | per package | on/off only |
| Web Blocker | per host | on/off, plus a per-site `pausedUntil` |
| Daily Limit | global | **display-only — never enforced** |

Two fields are already persisted with **zero producers and zero consumers**:
`AppBlockEntry.dailyLimitMinutes` and `AppBlockEntry.lockAction`. They are the shape of this
milestone, written down and never wired. `16-implementation-roadmap.md` names daily-limit
enforcement as the single remaining native follow-up.

A user cannot express "block Reels during work hours", "give me 30 minutes of Instagram a day", or
"I get 5 opens of TikTok". Those are table stakes for the category, and all three fall out of one
engine.

## What the user gets

Three rule kinds over the targets Detoxo already understands:

- **Schedule** — days of week + a time window (including overnight windows that cross midnight).
- **Daily time limit** — a per-target minute budget that *monitors* until it is spent, then locks
  until end of day or for a fixed duration.
- **Open limit** — N launches per day, then blocked.

Each rule targets any mix of reel platforms, apps, websites, and — via M0.1 — whole categories.

## Source: what is taken, what is dropped

**Taken** — the evaluation order, the midnight-wrap window arithmetic, the selection semantics, the
state-period roll, and the lock-period model. All are readable in the decompile.

**Dropped** — B2's drift schema (Hive instead), its Riverpod controllers, its 8-sheet flow (Detoxo
has its own design system), and the `Friction` rule type which `gp/a.java` shows was removed from
the source app itself.

**Corrections carried** — recorded because they contradict sibling docs in the same set:
`lockPeriod` / `lockDurationMillis` belong to **time-limit** details, not session details;
session details carry **no** unblock-selection columns; and B3's `activationType: Manual` /
`blockingSelectionType: AllowList | BlockList` **do not exist** — the real vocabularies are
`{DateInterval, Repeating, AlwaysOn}` and `{Block, AllExcept}`.

## Algorithm & control flow

### Evaluation

```
decide(target, now, tz) -> Allow | Block(rule, reason)

  rules = enabled rules, stable order: createdAtMs ascending
  for rule in rules:
      if (!isActiveNow(rule, now, tz)) continue
      if (!covers(rule, target))        continue
      if (isBlockingNow(rule, now, tz)) return Block(rule, reasonOf(rule))
  return Allow                                   // FIRST blocking rule wins
```

### `isActiveNow`

```
Disabled                                    -> false
Snoozed  && now <  snoozedUntilMs           -> false
Snoozed  && now >= snoozedUntilMs           -> clear the snooze (side effect), treat as Enabled
deleteAfterMs != null && now >= deleteAfterMs -> false        // soft delete
                                                              // all windows evaluated in
                                                              // rule.timezoneId ?? deviceTz
AlwaysOn                                    -> true
DateInterval                                -> startMs <= now <= endMs
Repeating                                   -> inWeeklyWindow(days, start, end, zoned(now))
```

### `inWeeklyWindow` — the midnight wrap

The one piece that is always got wrong when reimplemented from intuition:

```
inWeeklyWindow(days, start, end, t):           // days = ISO 1..7 (Mon..Sun)
    if (start <= end):                          // normal, e.g. 09:00 -> 17:00
        return today ∈ days && start <= t.time < end

    // overnight, e.g. 22:00 -> 06:00
    if (t.time >= start) return today ∈ days              // evening portion, counted on the START day
    if (t.time <  end)   return prevDay(today) ∈ days     // morning slice, ALSO attributed to the start day
    return false
```

The attribution rule is the subtle half: a "Fri 22:00–06:00" rule blocks at 02:00 on **Saturday**,
because Saturday's early hours belong to Friday's window. Getting this wrong produces a rule that
fires a day late and is nearly impossible to diagnose from a bug report.

### `covers`

```
selectionMatch = (target.isApp     && target.pkg    ∈ selection.apps)
              || (target.isWebsite && target.domain ∈ selection.websites)   // suffix-aware, M0.1
              || (categoriesOf(target) ∩ selection.categories ≠ ∅)
              || (target.isPlatform && target.platformId ∈ selection.platforms)

return selection.type == Block ? selectionMatch : !selectionMatch     // Block | AllExcept
```

### `isBlockingNow`

```
Schedule:
    true                                        // active + covered is enough

TimeLimit:
    period = currentStatePeriod(rule, now, tz)  // rolls at local midnight
    if (period changed) { stateReachedAtMs = null; emit budgetReset }
    used = usage.foregroundMillisFor(rule.monitored, period)     // M0.2
    if (used < thresholdMs) return false        // MONITORING ONLY — not blocking
    reachedAt = stateReachedAtMs ??= now
    return lockPeriod == EndOfDay
             ? now <  period.endMs
             : now <  reachedAt + lockDurationMs               // FixedDuration
    // remainingMs = thresholdMs - used  is exposed for the warning notification
    //               (fires at warningLeadTimeMs before zero)

OpenLimit:
    period = currentStatePeriod(rule, now, tz)  // rolls at local midnight, resets stateOpens = 0
    return stateOpens >= numberOfOpens
    // a granted launch consumes one open and increments stateOpens in ONE write

currentStatePeriod(rule, now, tz):
    if (statePeriodStartMs <= now < statePeriodEndMs) return the stored period
    p = todayInterval(tz)                        // local midnight -> next local midnight
    persist p; return p
```

`used < threshold` returning **false** is deliberate and easy to misread: a time-limit rule that
has not been exhausted is *not blocking*, it is *watching*. That distinction is what lets M4
report "22 of 30 minutes used" and what lets the warning notification exist at all.

### Where evaluation runs, and how native enforces

**Rules are evaluated in Dart. Native never parses a schedule.** This is the load-bearing
architectural decision and it follows the one precedent already in the codebase.

`pushWebBlocklist` already carries per-entry `pausedUntil` (epoch ms), and `WebBlockEngine`
enforces its expiry natively so a per-site pause re-arms *even if the Flutter app is never
reopened* — see the comment at
[`engine/WebBlockEngine.kt`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt).
M3 generalises exactly that shape:

```
Dart, on any rule change / app resume / boundary event:
    snapshot = rules.map { r -> resolved(r) }     // categories -> flat package + domain lists
    nextBoundaryMs = min over all rules of the next time any window opens or closes
    channel.pushRules({ rules: snapshot, nextBoundaryMs })

Native, per foreground event (hot path):
    for r in snapshot:                            // small array, O(rules), no parsing
        if (now < r.activeFromMs || now >= r.activeUntilMs) continue   // plain long compare
        if (!r.targets.contains(pkg)) continue
        return BLOCK(r.reason)

Native, at nextBoundaryMs:
    ConfigStore.nextBoundaryMs is checked by the EXISTING WatchdogJobService tick (15 min)
    and on every WINDOW_STATE_CHANGED; when passed, post `ruleBoundary` so Dart re-pushes.
```

Each snapshot entry carries an **already-resolved absolute window** (`activeFromMs` /
`activeUntilMs`) rather than a recurrence rule, so native does two long comparisons and a set
lookup. No parsing, no timezone maths, no new ticker — the invariant in
[00](00-index.md#budget-guardrails) holds.

**Time-limit consumption** is reconciled, not accrued on the hot path: Dart queries M0.2's
`queryAppUsage` for the current period on app resume and on the watchdog tick, then re-pushes a
snapshot whose `activeFromMs` is `now` if the budget is spent. Native never counts minutes.

`ponytail: limit enforcement is reconciled at most every 15 min (watchdog) or on resume, so a
budget can overrun by up to one watchdog interval. Upgrade path = an AlarmManager set to the
projected exhaustion time.` — record this at the push site. It is a real and acceptable ceiling
for a v1: a daily limit that is a few minutes late is still a daily limit; a new 1 Hz ticker to
make it exact is not worth the battery.

### Boundary notifications

E1's supersede table is the idea worth taking. `flutter_local_notifications` is **already declared
in `pubspec.yaml` and wired to nothing** — this is its first real use.

Ledger ids follow `<category>:<entityId>:<...>`; the prefix is what a cancel matches, so the
convention is load-bearing.

| Posting | Supersedes |
|---|---|
| `schedule.started` | `schedule.starting_soon` |
| `schedule.complete` | `schedule.starting_soon`, `schedule.started` |
| `limit.reached` | `limit.warning` |

Never schedule in the past (`fireAt <= now` → skip). Re-scheduling the same id **replaces**.

## Data model

Hive, key `StoreKeys.rules`, one JSON array. **Enums persist as stable name strings**; a rename is
a migration.

```jsonc
[{
  "id": "uuid",
  "name": "Work hours",
  "kind": "SCHEDULE",                    // SCHEDULE | TIME_LIMIT | OPEN_LIMIT
  "enabledState": "ENABLED",             // ENABLED | DISABLED | SNOOZED
  "snoozedUntilMs": null,
  "createdAtMs": 1756742400000,
  "deleteAfterMs": null,
  "timezoneId": null,                    // null = device zone
  "activation": {
    "type": "REPEATING",                 // DATE_INTERVAL | REPEATING | ALWAYS_ON
    "repeatDays": [1,2,3,4,5],           // ISO 1..7, Mon..Sun
    "timeStart": "09:00",                // "HH:mm", 24h
    "timeEnd":   "17:00",
    "startMs": null, "endMs": null       // DATE_INTERVAL only
  },
  "selection": {
    "type": "BLOCK",                     // BLOCK | ALL_EXCEPT
    "platforms":  ["ig_reels"],
    "apps":       ["com.instagram.android"],
    "websites":   ["instagram.com"],
    "categories": ["short_form_video"]
  },
  "timeLimit": {                         // TIME_LIMIT only
    "thresholdMs": 1800000,
    "warningLeadTimeMs": 300000,
    "lockPeriod": "END_OF_DAY",          // END_OF_DAY | FIXED_DURATION
    "lockDurationMs": 0,
    "monitored": { "apps": [], "websites": [], "categories": [] },
    "statePeriodStartMs": 0, "statePeriodEndMs": 0, "stateReachedAtMs": null
  },
  "openLimit": {                         // OPEN_LIMIT only
    "numberOfOpens": 5,
    "statePeriodStartMs": 0, "statePeriodEndMs": 0, "stateOpens": 0
  }
}]
```

The wire snapshot is deliberately **smaller and dumber** than the stored rule — see
[09](09-contracts-and-storage.md).

Native `detoxo_engine_prefs` gains `rules_json` (the snapshot) and `next_boundary_ms`. If
`rules_json` grows past a few KB it moves to its own prefs file, exactly as
`detoxo_platforms_config` was split out so hot-path counter writes stopped re-serialising 31 KB.

## Channel delta

| Method | Args | Returns |
|---|---|---|
| `pushRules` | `{json: String, nextBoundaryMs: Long}` | `true`; no-op on null/non-array, like `pushWebBlocklist` |

New events: **`ruleBoundary`** `{atMs: Long}` — a pushed window opened or closed; Dart recomputes
and re-pushes. **`usageLimitReached`** `{ruleId, targetId}` — a limit tripped natively.

## Module layout

```
lib/features/limits/rules/
├── domain/entities/{rule,rule_kind,activation,selection,rule_target,verdict}.dart
├── domain/repositories/rule_repository.dart
├── domain/usecases/{evaluate_rules,resolve_snapshot,next_boundary}.dart   # PURE, no platform imports
├── data/repositories/rule_repository_impl.dart
└── presentation/{rules_cubit.dart, rules_screen.dart, rule_editor_screen.dart}

android/.../engine/RuleEngine.kt        # Android-free: snapshot + now -> Block?   (JVM-tested)
```

`evaluate_rules`, `inWeeklyWindow`, `currentStatePeriod` and `next_boundary` are **pure functions
with zero platform imports** — the whole calendar is unit-testable with no device. This is D1's
best structural idea applied here, and it matches `StreakCubit.advance`.

## Reuse map

| Existing | Take |
|---|---|
| `engine/WebBlockEngine.kt` | The whole shape: `@Volatile` rule list, `setBlocklist(json)` replace, `hasAnyRules()` hot-path guard, per-entry `pausedUntil` expiry enforced natively. `RuleEngine.kt` is its sibling |
| `pushWebBlocklist` | The exact fail-safe contract: null/non-array → no-op, skip if unchanged |
| `engine/ReelTracker.kt` + `ReelTrackerTest.kt` | Android-free Kotlin object with a JVM test in the precommit gate |
| `receivers/WatchdogJobService.kt` | The 15-minute tick that already exists — ride it, do not add a job |
| `engine/DateKeys.kt` | `dd-MM-yyyy` day keys, memoised per wall-clock minute, default TZ re-applied per call |
| `AppBlockEntry.dailyLimitMinutes` / `.lockAction` | The persisted-but-unwired fields this milestone finally gives producers and consumers |
| `DailyLimitCubit` | The existing global limit becomes one `TIME_LIMIT` rule with an all-targets selection — migrate it, do not run two limit systems |
| `intl` (declared) | `HH:mm` parse/format and weekday names |

## Steps

1. Domain entities + the pure use-cases, with tests written **first** — the calendar edge cases are
   the deliverable.
2. `RuleRepository` + Hive impl under `StoreKeys.rules`.
3. `resolve_snapshot`: categories → flat package/domain lists (M0.1), recurrence → absolute
   `activeFromMs`/`activeUntilMs`, plus `next_boundary`.
4. `RuleEngine.kt` + JVM tests; `pushRules` arm; `ConfigStore` keys.
5. Hot-path integration in `DetoxoAccessibilityService`, placed to resolve the ordering question
   M2.2 raised (whole-app block currently sits **above** the pause gate — decide and document
   whether a rule block does too).
6. Boundary check in `WatchdogJobService` + on `WINDOW_STATE_CHANGED`; `ruleBoundary` post.
7. Time-limit reconciliation from M0.2 on resume + watchdog.
8. Boundary notifications via `flutter_local_notifications` with the supersede table.
9. Rules list + editor screens; migrate `DailyLimitCubit` onto a rule.
10. `/docs-sync` — 03, 04, 06, 07, 09, 18 + `info_docs/02` and FAQs.

## Risks & ceilings

- `ponytail: limits reconcile at most every 15 min or on resume; a budget can overrun by one
  watchdog interval.` (at the push site)
- `ponytail: snapshot windows are absolute and expire at nextBoundaryMs; if the process is dead and
  the watchdog is deferred, a window can open late.` (at `RuleEngine`)
- **DST and timezone travel.** `todayInterval(tz)` must use real zone arithmetic, not
  `now - now % 86400000`. A DST day is 23 or 25 hours long. `DateKeys.kt` already re-applies the
  default timezone per call for exactly this reason — mirror it.
- **Rule explosion on the hot path.** Native iterates the snapshot per event. Cap the rule count
  (start at 50) and keep `hasAnyRules()` as the first guard, as `WebBlockEngine` does.
- **Do not retune** `THROTTLE_MS 150` / `BLOCK_DEBOUNCE_MS 1200` / `BACK_RATE_LIMIT_MS 1100` /
  `MAX_NODES 12000` to accommodate rules.
- **Enum strings are a storage contract.** A rename without a migration silently drops rules.

## Validation

- [ ] `bash tool/dev.sh precommit` passes, native JVM tests included
- [ ] Pure-function tests cover: normal window; overnight window at 23:00 and at 02:00 (the
      previous-day attribution); a window that starts and ends at the same minute; DST spring-forward
      and fall-back days; `used == threshold` exactly; period roll across local midnight;
      `Snoozed` expiring mid-evaluation; `AllExcept` with an empty selection; first-blocking-rule-wins
      ordering with two overlapping rules
- [ ] `RuleEngineTest.kt` covers: empty snapshot is a no-op; expired window does not block;
      malformed JSON leaves the previous snapshot intact
- [ ] Rules survive process death and reboot (`ConfigStore` + `BootReceiver` path)
- [ ] With rules empty, hot-path behaviour is byte-identical to today
- [ ] Device sanity: a 2-minute schedule fires and releases; a 1-minute limit locks and releases at
      midnight; an overnight rule blocks after midnight; service reconnects after toggling
      accessibility
- [ ] `pubspec.yaml` unchanged (`flutter_local_notifications`, `intl`, `uuid`, `collection` are
      already declared)
- [ ] `tool/boundaries_baseline.txt` line count ≤ 8

## Target files

**New** — `lib/features/limits/rules/**` · `android/.../engine/RuleEngine.kt` ·
`android/app/src/test/RuleEngineTest.kt` · `test/rules_engine_test.dart` ·
`test/rules_calendar_test.dart`

**Edited** — `android/.../accessibility/DetoxoAccessibilityService.kt` ·
`android/.../channels/CommandHandler.kt` · `android/.../engine/ConfigStore.kt` ·
`android/.../receivers/WatchdogJobService.kt` · `lib/core/constants/channel_constants.dart` ·
`lib/core/storage/local_store.dart` · `lib/core/di/injector.dart` ·
`lib/features/limits/limits.dart` · `lib/features/limits/daily_limit/**` (migrate onto a rule) ·
`lib/core/navigation/{routes,app_router}.dart`
