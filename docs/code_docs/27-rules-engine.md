# Rules Engine (schedules, daily time limits, open limits)

Written from shipped source. Rules are Detoxo's first **time-aware** blocking: a weekly
**schedule** ("Reels and Instagram, weekdays 09:00–17:00"), a **daily time limit** ("30 minutes of
Instagram a day, then blocked until midnight") and an **open limit** ("5 launches a day"). The same
machinery finally **enforces the global Daily Limit** that [07](07-daily-limit-scheduler.md) used
to document as display-only. Plan doc: [`plan_docs/04-M3-rules-engine.md`](../plan_docs/04-M3-rules-engine.md)
(shipped, lean core — see its deviations list). Hardened and extended by EVO-028 (the wall names its
release time), EVO-029 (native limit reconciliation), EVO-030 (strict rules) and EVO-031 (presets).

The load-bearing decision: **rules are evaluated in Dart; native never parses a schedule.** Dart
resolves every rule into a flat snapshot with absolute windows and pushes it; the native
`RuleEngine` does two long compares and a set lookup per event. This is the `pushWebBlocklist` /
`pausedUntil` precedent generalised.

---

## 1. Layout

```
lib/features/limits/rules/
├── domain/entities/rule.dart            Rule, RuleKind, SelectionMode, RuleSelection, RuleSchedule, maxRules
├── domain/entities/rule_snapshot.dart   TimeWindow, SnapshotEntry, RulesSnapshot, RuleStatus (MIRROR CONTRACT)
├── domain/repositories/rule_repository.dart
├── domain/usecases/rule_calendar.dart   inWeeklyWindow, scheduleWindows, todayInterval, countOpens — pure
├── domain/usecases/resolve_snapshot.dart rules + usage + now → snapshot + per-rule status — pure
├── domain/usecases/rule_summary.dart    the list / pill / dashboard copy — pure
├── domain/rule_sync.dart                syncRules(): THE push path
├── data/repositories/rule_repository_impl.dart
└── presentation/{rules_cubit, rules_screen, rule_editor_screen}.dart

android/.../engine/RuleEngine.kt         Android-free: snapshot + now → blocking Entry?  (JVM-tested)
lib/features/dashboard/presentation/widgets/rules_card.dart   the dashboard entry point
```

The `limits.dart` barrel exports the domain, `syncRules` and — like `content_counter.dart` — the
app-wide `RulesCubit`, so the dashboard card and `AppResumeSync` reach it without a boundary
violation. `tool/boundaries_baseline.txt` is unchanged (zero entries).

## 2. Data model — Hive `StoreKeys.rules`

One JSON array of rule documents in the plan-doc vocabulary, so the deferred fields (snooze, date
ranges, fixed-duration locks) are additive. Enums persist as stable name strings; every field is
read **null- and type-tolerantly** (a wrong-typed field degrades that field — a cast would throw out
the whole list); a document with an unknown `kind`, a non-object element, or anything that throws
while parsing is **dropped on its own** (logged) rather than taking the list down; a corrupt blob
**throws** (the web-blocker contract — the sync must abort rather than push `[]`, which native
honours as a clear). `RulesCubit` refuses every mutation until a load has actually succeeded, so a
failed read can never be saved back over the real list.

```jsonc
{ "id": "uuid", "name": "Work hours", "kind": "SCHEDULE" | "TIME_LIMIT" | "OPEN_LIMIT",
  "enabledState": "ENABLED" | "DISABLED", "createdAtMs": 1756742400000,
  "selection": { "type": "BLOCK" | "ALL_EXCEPT", "platforms": ["ig_reels"], "apps": ["com.instagram.android"],
                 "websites": ["instagram.com"], "categories": ["short_form_video"] },
  "activation": { "type": "REPEATING", "repeatDays": [1,2,3,4,5], "timeStart": "09:00", "timeEnd": "17:00" }
              | { "type": "ALWAYS_ON" },                       // limits
  "timeLimit": { "thresholdMs": 1800000, "lockPeriod": "END_OF_DAY" },   // TIME_LIMIT only
  "openLimit": { "numberOfOpens": 5 },                                   // OPEN_LIMIT only
  "strict": true,                         // EVO-030, omitted when false — a Pause cannot lift it
  "locked": true, "lockScope": "DISTRACTING" }   // M8, both sparse; SELECTION is the default
```

- `RuleSchedule.days` are ISO weekdays (`DateTime.weekday`, 1 = Mon … 7 = Sun); `startMin` /
  `endMin` are minutes after local midnight; `endMin < startMin` is an **overnight** window;
  `startMin == endMin` never matches and the editor refuses it.
- **No stored limit state.** Used minutes and opens are re-derived from UsageStats on every
  reconcile — nothing to migrate, nothing to drift. Native holds a *runtime* spent flag between
  reconciles (§6, EVO-029); Dart's next push overwrites it.
- **`locked` (M8)** has no off switch: `LockGuard`, called from the one choke point every
  mutation funnels through (`RulesCubit._commit`), refuses disabling, deleting, unlocking,
  narrowing the selection, **changing the schedule**, **changing the rule's kind** and **loosening
  the budget — including tightening it to zero** — because moving a locked window to 03:00–03:01,
  dragging a 30-minute limit to 240, or re-saving it as a different machine with the same id all
  neuter the rule for free. Zero is the subtle one: `resolveSnapshot` emits no entry at all for a
  limit at zero, so "tightening" to nothing *disables* the rule while travelling the one direction
  the guard waves through. The kind and zero clauses are unreachable from today's editor; they are
  held because `LockGuard` is billed as the choke point every future caller inherits. Renaming and *widening the selection* stay allowed. It is set once at creation and never
  cleared; the only relief is an override. It **implies `strict`** on the wire (`Rule.isStrict`),
  so the snapshot gains no key. `lockScope: DISTRACTING` widens a `SCHEDULE` in `BLOCK` mode to
  every distracting package the catalog names — never a limit (that would widen its *budget*) and
  never an `ALL_EXCEPT` rule (that would invert it). See
  [31](31-locked-rules-and-unblock.md) §4.
- `maxRules = 50`, enforced by `RulesCubit.save`. The native parser caps at **51**
  (`RuleEngine.MAX_ENTRIES`) because the synthetic daily-reel-limit entry is appended *after* the
  rules — capping at 50 truncated exactly that entry and silently stopped enforcing the global
  Daily Limit.
- **Presets** (EVO-031): `RulePreset.all` is a `const` list of starter rules ("Work hours",
  "Sleep", "Dinner", "Doomscroll budget"). Tapping one opens the editor **pre-filled**; nothing is
  saved until the user confirms, and a saved preset is an ordinary rule with no marker on it.
- **Open** limits target apps and categories only — a launch is counted per package, and a feed has
  none. A **time** limit does too when it names apps, and falls back to native reel-time metering
  when its targets are feeds alone (§3 step 4). Schedules target every dimension.

## 3. Evaluation — pure Dart

`rule_calendar.dart` (no platform imports; the whole calendar runs on a dev machine):

- `inWeeklyWindow(days, start, end, t)` — the midnight wrap done right: for "Fri 22:00 → 06:00",
  02:00 on **Saturday** is inside (Friday's window), 02:00 on Friday is not.
- `scheduleWindows(schedule, from, horizonDays: 7)` — absolute `TimeWindow`s for the next 7
  calendar days from `from` (device zone), including an already-open window and, for an overnight
  rule, one that began yesterday; finished windows are dropped. Built with `DateTime(y, m, d + i)`
  **calendar arithmetic**, never `add(Duration(days: 1))` — a DST day is 23 or 25 h long.
- `todayInterval(now)` — local midnight → next local midnight (a limit's state period).
- `countOpens(events)` — foreground **transitions** into a package (an app resuming its own next
  activity is not a new open — the same rule as native `UsageQuery.countOpens`).

`resolve_snapshot.dart` — `resolveSnapshot({rules, now, usageMsByPackage, opensByPackage,
usageKnown, dailyReelLimit, catalog, horizonDays})` → `RulesEvaluation(snapshot, statuses)`:

1. Enabled rules in `createdAtMs` order — native takes the **first** blocking entry, so order is
   the tie-break. Disabled rules map to `RuleStatus.off`.
2. Targets flatten through the catalog ([26](26-catalog-and-usage-signal.md)): a **category**
   contributes its services' packages **and** their domains (a category is "the service"); an
   explicitly picked app stays app-only, like the App Blocker; websites are `normalizeHost`ed.
3. `SCHEDULE` → one entry with every window in the horizon (omitted when there is none);
   `activeNow` / `nextChangeMs` from the open or next window.
4. `TIME_LIMIT` → spent when `usageKnown && used ≥ thresholdMs`: one entry with
   `reason: DAILY_LIMIT` and `windows: [[todayStart, todayEnd]]` (anchored to the period, not
   "now", so a re-push a minute later is byte-identical). Unspent → no entry, but `now + remaining`
   joins the boundary. `OPEN_LIMIT` → spent when `opens ≥ numberOfOpens`, same entry shape.
   The entry carries `platformIds` as well as packages and domains, so a spent budget on a category
   closes the feeds the rule named too.
   **A time limit whose targets are FEEDS and nothing else is reel-metered instead**: `_sum` runs
   over packages, so a feed-only limit measured 0 forever and could never spend, and dropping
   `platformIds` meant it covered nothing either — the shape onboarding's starter rule takes for
   four of six survey answers, including "skip". Such an entry ships `reelTimeLimitMs` (and no
   `usageLimitMs`), which native already meters with Detoxo closed, exactly as it does for the
   global Daily Limit at step 6. `isMeteredLimit` covers only the budgets Dart measures, so a
   reel-metered entry is never treated as pending.
5. `usageKnown == false` (no grant / no engine) ⇒ **nothing is spent** and the status says so —
   fail-open, never a confident zero (EVO-014).
6. `dailyReelLimit > 0` appends the synthetic entry `{id: "daily_reel_limit", reason: "DAILY_LIMIT",
   platformIds: ["*"], always: true, reelTimeLimitMs}` **last**.
7. An **active override** (M8) subtracts its window from that rule's own entry windows via the pure
   `subtractWindow`, splitting them — a 09:00–17:00 schedule lifted 10:00–11:00 pushes
   `[[09:00,10:00],[11:00,17:00]]`. Native needs no change (`Entry.isActive` already walks a flat
   pair array) and re-arms at 11:00 by its existing long compare, with Flutter dead. A spent limit
   keeps `spent: true` while split, so the watchdog reconciler cannot re-close the override.
   Scoping the lift to the RULE rather than to its targets is what keeps a sibling rule and the App
   Blocker row untouched. See [31](31-locked-rules-and-unblock.md) §4.
8. `nextBoundaryMs` = the earliest of every window edge > now, each unspent time limit's projected
   exhaustion, local midnight whenever a limit exists, and each active override's end; `0` with no
   entries.

`rule_summary.dart` — `describe(rule)` ("Weekdays · 09:00–17:00 · 2 apps, 1 category" — counts,
never labels, so the list renders without the installed-apps scan), `status(rule, status, now)`
(the pill: "Off" / "Active now" / "Limit reached" / "22/30 min" / "3 of 5 opens" /
"Needs usage access" / "Next Mon 09:00"), `nextEvent(...)` (the dashboard subtitle), `clock(ms, now)`
("09:00" today, "Mon 09:00" otherwise — 24 h like the web blocker's "Paused until").

## 4. The push path — `syncRules`

`rule_sync.dart` — `syncRules(RuleRepository, DailyLimitRepository, UsageRepository,
EngineRepository, {now})` → `RulesEvaluation?`. The `syncWebBlocklist` shape: try/catch →
`AppLogger.e`, a failed `load()` **aborts** (native keeps its last-good snapshot). UsageStats is read
only when an enabled limit rule exists (`queryAppUsage` + `queryUsageEvents` over
`todayInterval`; skipped at exactly midnight, when the window would be empty); `UsageDenied` /
`UsageUnavailable` → `usageKnown = false`. Then `engine.pushRules(json, nextBoundaryMs)`.

Its single caller is `RulesCubit` (§7): on `load()` (cold start), on every mutation, on every
resume (`AppResumeSync`'s cheap leg — `guardedSync('rules', RulesCubit.resync())`), on native
`ruleBoundary`, on a one-shot timer to the next boundary, and when the Daily Limit changes
(`main.dart`'s `BlocListener<DailyLimitCubit>`). `syncEngineBlocklists()` deliberately does **not**
carry a rules leg — one owner, one push path.

> `ponytail:` limits reconcile from UsageStats only while Dart runs, so a spent budget can enforce
> late if Detoxo is not opened (native has no minute counter; the daily reel limit is the exception
> — its meter is native). Upgrade path = native reconciliation at the watchdog tick via
> `UsageQuery`.

## 5. Wire contract

**`pushRules {json: String, nextBoundaryMs: Long}`** — the arm is `pushWebBlocklist`'s twin
(`CommandHandler.kt`): an absent / non-JSON-array `json` is a **no-op** (never a wipe; clearing needs
an explicit `"[]"`), an unchanged `json` skips the prefs rewrite, `nextBoundaryMs` is **always**
written (read as `Number` — Flutter marshals small longs as `Integer`, and it is clamped to ≥ 0 so a
negative can never read as "no boundary"), then `service.refreshRules()` re-reads both. The engine
re-parses only when the snapshot **string** actually changed (`RuleEngine.setSnapshot` holds the last
source), and spent-limit entries are built to be byte-identical across re-pushes — so the common
resume / boundary push costs no parse at all. Always `true`.

The snapshot — **one entry per rule**, nested windows (a shipped delta from the plan docs' flat
`activeFromMs/activeUntilMs`, recorded in [`plan_docs/09`](../plan_docs/09-contracts-and-storage.md)):

```jsonc
[{ "id": "uuid", "reason": "SCHEDULE" | "DAILY_LIMIT", "mode": "BLOCK" | "ALL_EXCEPT",
   "packages": ["com.instagram.android"], "domains": ["instagram.com"], "platformIds": ["ig_reels"],
   "windows": [[fromMs, untilMs], ...],   // absolute, sorted, ≤ 7 days ahead, device zone
   "always": false,                        // true → ignore windows (the daily reel limit entry)
   "reelTimeLimitMs": 0,                   // > 0 → native meter (the daily reel limit entry only)
   "strict": false,                        // EVO-030: enforced ABOVE the pause gate
   "usageLimitMs": 1800000,                // EVO-029: the rule's own daily budget (0 = not a time limit)
   "openLimitCount": 0,                    // EVO-029: its launch allowance (0 = not an open limit)
   "spent": false }]                       // EVO-029: false = PENDING — native measures, never blocks
```

**Pending vs spent.** A limit rule contributes an entry for today's whole period **whether or not
its budget has run out**. `spent: false` means native must *measure* it (§6) and must *not* block on
it; `spent: true` means it blocks. Before EVO-029 an unspent limit contributed nothing, so a daily
budget could not start enforcing until Dart next ran.

`nextBoundaryMs` is the earliest of: every window edge after now, each unspent limit's projected
exhaustion, and local midnight when any limit exists. It is pushed **unconditionally** — a
limits-only snapshot has no entries to block on yet but still needs native and the timer to come
back. The projection is floored at 60 s: it assumes continuous use, so as a budget nears zero it
lands arbitrarily close to `now`, and re-arming there spun a query + resolve + push loop until
midnight whenever the app was in fact idle.

**Event `ruleBoundary {atMs}`** (not sticky): native posts it **once** when `next_boundary_ms` has
passed — checked on every `WINDOW_STATE_CHANGED` against a `@Volatile` mirror and on the 15-minute
watchdog tick — then zeroes it; Dart's re-push arms the next. With no Dart listener it is dropped;
the next resume re-pushes regardless.

The existing **`blocked`** event gains `reason` (`PLAN` | `APP_BLOCK` | `SCHEDULE` | `DAILY_LIMIT`)
and uses `platformId: "rule"` for a rule's HOME bounce (`"app_block"` stays for App Blocker locks).
Dart's `BlockEvent` ignores the new key. No `usageLimitReached` event: `blocked` covers it.

## 6. Native — `engine/RuleEngine.kt` + the hot path

`RuleEngine` is Android-free (like `ReelTracker`): `Entry(id, reason, allExcept, packages: Set,
domains, platformIds: Set, windows: LongArray [from0, until0, …], always, reelTimeLimitMs, strict,
usageLimitMs, openLimitCount, spent)` inside a single immutable `Snapshot` swapped as **one**
`@Volatile` reference — separate fields could be read half-updated by a concurrent event (new
entries, stale gates).

- `setSnapshot(json)` — blank clears; a **malformed payload keeps the previous snapshot**; an
  unchanged **source string** is a no-op (no re-parse); rows without an `id` are skipped; capped at
  `MAX_ENTRIES = 51` (= `maxRules` + the synthetic daily-limit entry). The `Snapshot` precomputes
  every hot-path gate: `hasPackageRules` (a blocking entry names a package), `hasHostRules`,
  `hasReelMeter`, `hasStrictRules`, `hasStrictPlatformRules`, `hasPendingLimits`.
- **"No rules" is not "no entries."** A user with zero rules but a global Daily Limit set still has
  the synthetic meter entry, so `hasAnyRules()` is true for them. The package arm is gated on
  `hasPackageRules()` for exactly that reason — it runs above the throttle on nearly every
  foreground event.
- `activeUntil(now)` returns the end of the window covering `now` (0 for an `always` entry) — the
  wall's "Unlocks at …" line (EVO-028).
- `isActive(now)` = `always || any window contains now` (start inclusive, end exclusive).
- **`ALL_EXCEPT` inverts membership only within a LISTED dimension** — an empty `packages` list
  targets no package, so a platform-only "all except" rule never HOME-bounces every app. (A
  deliberate deviation from B2's "empty AllExcept blocks everything".) The editor emits `BLOCK`
  only; `ALL_EXCEPT` is carried end to end for a later focus mode.
- `blockingForPackage(pkg, now, strictOnly)` / `blockingForHost(host, now)` (exact or
  `isSubdomainOf`, the one copy of that rule — `WebBlockEngine` calls it) /
  `blockingForPlatform(platformId, now, reelTimeTodayMs, strictOnly)` (`"*"` wildcard; a meter entry
  blocks only once `reelTimeTodayMs ≥ reelTimeLimitMs`). **A meter entry applies to reel surfaces
  only** — never to a package or a host; a **pending** limit entry blocks nothing at all. Each arm
  tests the cheap set lookup *before* the window scan (both are pure, so the result is identical but
  entries that do not name the target never walk up to 7 days of windows). First match wins.

### Native limit reconciliation (EVO-029)

`engine/LimitReconciler.kt` (Android-free, JVM-tested) takes today's per-package foreground ms and
launch counts and returns the pending entry ids whose budget is used up — summed **across** a rule's
packages, so a category rule is one budget, matching Dart's `_sum`. `RuleEngine.markSpent(ids)`
rebuilds the snapshot with those entries flipped, recomputing every gate.

`WatchdogJobService.reconcileLimits(context)` runs it on the existing 15-minute tick, gated on
`hasPendingRuleLimits()` and `UsageQuery.hasAccess`, and posts `ruleBoundary` on a real flip so a
live Dart re-resolves and agrees. **No new job, no alarm, no new permission** — `PACKAGE_USAGE_STATS`
is already declared. Dart stays authoritative: its next push re-derives every verdict and overwrites
whatever native decided.

`ConfigStore`: `next_boundary_ms` (Long, 0) stays in the hot `detoxo_engine_prefs`, but `rules_json`
lives in its **own** `detoxo_rules_snapshot` file, migrated out once on first construction exactly
like the platforms config. Measured against the shipped catalog the snapshot is ~45 KB typical and
~175 KB worst case at the 50-rule cap (a category flattens to every package *and* domain in it),
while the counter flushes usage into the hot file every 5 s — which would re-serialise the whole
snapshot with it, 12×/min, all session.

`ContentCounter.timeTodayMs(now)` exposes the reel-time meter
(`ContentCounterStore.timeTodayMs(dateKey)`), memoised for `USAGE_FLUSH_MS` — a detector match
recurs continuously while a reel is on screen, so this ran up to 6.7×/s per matching platform for a
value the counter only writes every 5 s.

`DetoxoAccessibilityService` — three arms plus the boundary check, all guarded by
`ruleEngine.hasAnyRules()` first so an empty snapshot leaves the hot path byte-identical:

| Where | What |
|---|---|
| `TYPE_WINDOW_STATE_CHANGED` block, after the foreground update | `checkRuleBoundary(now)` — one long compare against the mirror; when passed: zero mirror + prefs, post `ruleBoundary`. Public so the watchdog can call it. |
| **Right after the Pause gate**, before the One Reel scroll capture and the throttle | **Package arm** — foreground-anchored like the App Blocker arm (`WINDOW_STATE_CHANGED || pkg == foregroundPkg`): `blockingForPackage` → `onAppBlocked(pkg, reason)` (HOME bounce, the wall with the rule's reason, shared HOME debounce, `blocked{platformId:"rule", reason}`). |
| Browser gate + `handleBrowser` | The gate is `webEngine.hasAnyRules() \|\| ruleEngine.hasHostRules()`; when `webEngine.matchHost` is null, `blockingForHost` runs; a hit follows the web-block path with `source: "RULE"`, the host named, `blockReason = entry.reason`. |
| Detector loop, **before** the Conscious / One Reel allow checks | **Platform arm** — `blockingForPlatform(platformId, now, timeTodayMs)` (the prefs read happens only when a meter entry exists, and only after a detector match); a hit calls `onDetected(..., ruleReason)`, which forces a count-only `NONE` mode to `PRESS_BACK`, raises `reelPayload(..., reason)` (so `sanitised()` drops the lying plan chip) and posts `blocked` with `reason`. |

**Pause semantics — decided here.** Rule blocks sit **below** the Pause gate by default: a Pause
(and, when M2 lands, an emergency pass) lifts them the way it lifts reel and web blocking. App
Blocker locks stay **above** the gate, unchanged.

**Strict rules (EVO-030)** are the per-rule opt-out, and a **locked** rule (M8) is one by
construction. A rule with `strict: true` gets a second pass
**above** the gate — same foreground anchoring, same wall — and the reel arm keeps working during a
Pause because `hasStrictPlatformRules()` lets the detection pass run and `strictOnly = paused`
narrows it to strict entries. Everything else a Pause used to lift still lifts: the One Reel scroll capture
and the plan checks are all explicitly `!paused`.

**M8 closed the website half of that scope note.** `strict` used to cover apps and reel feeds only,
so a two-minute Pause opened a strict rule's *websites* for free — which for a locked rule would
mean paying an override for what one tap gives away. `blockingForHost` gained `strictOnly` (its two
siblings already had it) plus a `hasStrictHostRules()` gate, and the browser arm now runs when
`!paused || ruleEngine.hasStrictHostRules()`, passing `strictOnly = paused` down through
`handleBrowser(pkg, paused)`. The user's own blocklist and every non-strict host rule still lift
during a Pause, exactly as before.

That gate is only reachable because the **pause early-return above it opens for both legs**:
`if (paused && !hasStrictPlatformRules() && !hasStrictHostRules()) return`. Gating that return on
platforms alone — as it did when the browser gate first shipped — silently voided the host half,
because a locked rule built from websites or from a category carries no `platformIds` at all (a
category flattens to packages + domains). Such a rule returned before the browser arm and its sites
were free for the whole Pause: the exact gap this paragraph claims to close. Both legs are
load-bearing; neither may be dropped. `reload()` (service connect / any settings push) re-applies
`store.rulesJson` and `store.nextBoundaryMs`, so rules survive process death and reboot with no
`BootReceiver` change.

`WatchdogJobService.onStartJob` runs `checkRuleBoundary` after `checkAndNotify` — through the live
service instance when there is one (it holds the mirror), else straight from prefs — then
`reconcileLimits`. No new job, no alarm, no ticker; the timing budgets (`THROTTLE_MS 150`, `BLOCK_DEBOUNCE_MS 1200`,
`BACK_RATE_LIMIT_MS 1100`, `MAX_NODES 12000`) are untouched.

> `ponytail:` windows are absolute and pushed 7 days ahead; with Detoxo unopened for longer a
> schedule silently lapses until the next open. Upgrade path = native recurrence evaluation.
> `ponytail:` device zone only — windows are resolved at push time, so a timezone change is
> honoured at the next re-push.
> `ponytail:` a native limit flip is up to one watchdog period (15 min) late and needs the
> accessibility service alive to hold the snapshot it flips. Upgrade path = persisting the flip
> through `ConfigStore` so it survives a service restart.
> `ponytail:` the Dart projection is floored at 60 s, so a Dart-side flip can be a minute late;
> enforcement no longer depends on it.

### A second consumer of `blockingForPackage`

Notification suppression ([29](29-notification-suppression.md)) asks the same resolver the
block arms do: `blockingForPackage(pkg, now, strictOnly = paused)`, per notification, from the
`SuppressionDecision` helper. Nothing about `RuleEngine` changed for it — the snapshot is
already in memory and the call is allocation-free — but it makes the resolver a **shared**
contract: an app is silenced exactly when opening it would raise the wall, so a change to the
arm order or the pause placement here must be mirrored in `SuppressionDecision` (§4 of 29).

## 7. Presentation

**`RulesCubit`** (app-wide, `main.dart`; `Cubit<RulesState{isLoading, loaded, rules, statuses,
hasUsageAccess, error}>`): `load()` → repo → `resync()`; `resync()` = `syncRules` → statuses +
(while a limit rule exists) `UsageRepository.hasAccess()` → re-arm a **one-shot** `Timer` to
`nextBoundaryMs + 1 s` (not a ticker); subscribes `EngineRepository.ruleBoundaryStream()` →
`resync()`. `save` / `remove` / `setEnabled` follow `WebBlockCubit._commit`: optimistic emit →
persist → revert + `error` on failure → `resync()`. `save` re-runs `Rule.validate()` — the same
helper the editor calls, so the two cannot drift — and refuses the 51st rule.

Two things the cubit guarantees that are easy to lose:

- **`resync()` is serialised.** A cold start fires two (its own `load()` and the `DailyLimitCubit`
  listener); without a chain their pushes could land out of order and leave native on the *older*
  snapshot.
- **`loaded` gates every mutation.** A failed load leaves an empty list; saving on top of it would
  replace the real rules on disk with one rule and a success toast.
- It also holds the **last snapshot** so a usage read that fails — transiently, or because the user
  just revoked the grant — cannot drop a limit entry that is already blocking. Unknown usage still
  never *starts* a block; it only holds one that is already up. Session-scoped: after a process
  restart there is nothing to carry and spent state is re-derived.

Since `RulesCubit`, `DailyLimitCubit` and `StreakCubit` only `..load()` once in `main.dart`, and
Settings → Reset app data wipes the store and then `context.go(Routes.splash)` **without restarting
the process**, `splash_screen.dart` re-loads all three — otherwise their state survives the wipe and
the next save writes it back.

**`RulesScreen`** (`Routes.rules = '/rules'`) — `GlassScaffold`, `InfoButton` (states the Pause
semantics), an `InlineHint` + "Grant usage access" (`PermissionRepository.request(AppPermission.usageAccess)`)
when a limit rule exists and the grant is not known-true, the pinned **Daily reel limit** row
(`DailyLimitCubit` + `ContentCounterCubit.timeToday`, → `Routes.dailyLimit`), then one
`GlassListTile` per rule (kind icon, name, `RuleSummary.describe`, status `Pill`, `AppToggle`; tap →
editor), and a FAB → kind picker sheet. It calls `resync()` on entry. The usage hint renders only
when the tri-state grant is **known false** — `!= true` flashed "limits cannot enforce" on every
cold entry, against the repo's own "render a neutral Checking… row" convention.

With no rules the screen shows `EmptyState` followed by **Start from a preset** (`RulePreset.all`):
the FAB is the blank-page entry point, these are the shortcut past it.

**`RuleEditorScreen`** (`Routes.ruleEditor = '/rules/edit'`, `extra: RuleEditorArgs{kind, rule?}` —
the router's first `extra`; a foreign extra opens a blank schedule): name; SCHEDULE → day `AppChip`s
(default Mon–Fri, labelled from `RuleSummary.dayLabel` and announced as full weekday names),
Starts / Ends via Flutter's `showTimePicker`, an "ends the next morning" hint for overnight windows
and an error for equal times; a **Strict** toggle (EVO-030); TIME_LIMIT → `AdaptiveSlider` 5–240 min;
OPEN_LIMIT → 1–20 opens; targets → category `AppChip`s (`AppCategorySeed.categories`), **Apps**
through the shared `showAppPickerSheet` (protected packages marked unavailable, as in the App
Blocker), and for schedules **Reel feeds** (`ConfigRepository.loadBlockTargets` filtered to installed,
non-browser targets) and **Websites** (`PopularSites` chips + a custom host through
`DomainValidator.check`). Validation: ≥ 1 target; ≥ 1 day and `start ≠ end` for a schedule.
Delete via `AppDialog.confirm(destructive: true)`.

**Dashboard** — `RulesCard` (tinted `GlassCard` status row, `AppIcon.rules` = Lucide
`CalendarClock`) sits full-width between the session banners and the App / Web Blocker pair in
`DashboardTab`: success tint + pulsing `StatusDot` while a rule is live, the house accent when
rules exist but none is active, plain glass when none are set up; "N active" / "N on" /
"Not set up" `Pill`, `RuleSummary.nextEvent` as the subtitle, chevron; taps → `Routes.rules`.

**Daily limit screen** — "used" now reads `ContentCounterCubit.state.timeToday` (the meter that
enforces), and the banner tells the truth: enforced until midnight, or "Reel counter is off" when
the meter is disabled (`ContentCount.enabled == false`).

**Times are rendered in the device's 12/24-hour setting** (`core/utils/clock_format.dart`), because
`showTimePicker` honours it — picking "5:00 PM" and reading back "17:00" was a real mismatch.
`RuleSchedule.formatHHmm` stays the storage and wire form; `RuleSummary`'s `describe` / `status` /
`nextEvent` / `clock` take an optional `TimeFormat` and the UI passes the locale-aware one.

## 8. Deferred (lean core)

Boundary notifications (`flutter_local_notifications` stays unwired), snooze, `DATE_INTERVAL`
activation, `FIXED_DURATION` locks, `timezoneId`, soft delete, a separate `monitored` set, the
`usageLimitReached` event, and `ALL_EXCEPT` in the editor. Every one is additive to the stored
document and the wire.

## 9. Tests

- Dart `test/rules_calendar_test.dart` — normal window; overnight at 23:00 Fri and 02:00 Sat (and
  not Fri / Sun 02:00); `start == end` never; a Mon–Fri horizon from Sunday yields five 09:00/17:00
  windows; an open window is kept, a finished one dropped; yesterday's overnight window is included;
  DST-date windows keep 09:00 / 17:00 local (consecutive starts 23–25 h apart on a DST machine);
  `todayInterval`; `countOpens`; `HH:mm` round-trip.
- Dart `test/rules_engine_test.dart` — the resolver (flattening, omission, ordering, `ALL_EXCEPT`
  passthrough, `used == threshold` spent, projected boundary, unknown usage never spends, open
  limit, the daily reel limit entry, the wire keys), `Rule` JSON round-trips + unknown kind dropped,
  `syncRules` (push, abort on corrupt, denied → unspent, granted spends via usage and via
  `countOpens`), `RuleSummary` copy, and `RulesCubit` (load pushes, optimistic save, failed save
  reverts, toggle off pushes `[]`, `ruleBoundary` re-pushes, the 50-rule cap). Plus the regressions
  this feature actually had: a limits-only snapshot still pushes its boundary; a nearly-spent limit
  floors its projection to a minute; a mutation after a failed load is refused, never written; a
  wrong-typed field degrades that field instead of the list; a spent category limit closes its
  websites; unknown usage holds a block that is already up; every preset validates and resolves.
- JVM `engine/RuleEngineTest.kt` (with `testImplementation("org.json:json")`, so the parse itself
  runs) — empty / blank; active vs expired / future windows (end exclusive); `always`; `"*"`;
  the reel meter at / below the limit and never on a package or host; `ALL_EXCEPT` within listed
  dimensions; host suffix match; first wins; malformed keeps the previous snapshot; missing ids
  skipped; the cap leaves room for the synthetic daily-limit entry (51); a meter-only snapshot never
  arms the package arm; `activeUntil` names the covering window; `strictOnly` sees only opted-in
  rules; `isSubdomainOf`.
- JVM `engine/LimitReconcilerTest.kt` — a budget is spent at the threshold, not before; a category
  budget is one sum across its packages; open budgets count launches and unknown packages contribute
  nothing; a flipped limit starts blocking and arms the package arm, and re-flipping is idempotent.
- `test/rules_screen_semantics_test.dart` — the `!semantics.parentDataDirty` class from
  `web_block_screen_semantics_test.dart`: a `ruleBoundary` and a toggle flip while the screen is
  open must not corrupt the semantics tree.
- `test/resume_sync_test.dart` pins `RulesCubit.resync()` on the cheap leg;
  `test/plans_pause_curious_test.dart`'s fake engine grew the two new members.
- Device sanity (not automatable here): a 2-minute schedule on a reel feed raises "Blocked by a
  schedule" and releases; a schedule on the app itself HOME-bounces; an overnight rule blocks after
  midnight; a website schedule BACKs the browser; Pause lifts a schedule but not an App Blocker
  lock; Daily Limit 1 min → after a minute of reels the wall reads "Your daily limit is used up";
  a 1-minute time limit locks on the next resume / boundary and the tile shows "Limit reached";
  rules survive process death, reboot and toggling accessibility. Since this pass: the wall reads
  "Unlocks at HH:MM" with the correct time in both 12- and 24-hour device settings; a **strict** rule
  still blocks during a Pause while a non-strict one does not, and an App Blocker lock is unaffected;
  a 1-minute time limit engages **without opening Detoxo** (force-stop Detoxo, use the target app,
  wait a watchdog tick); Settings → Reset app data leaves no rules behind.

## Source files

- `lib/features/limits/rules/domain/entities/{rule,rule_snapshot,rule_preset}.dart`
- `lib/features/limits/rules/domain/repositories/rule_repository.dart`
- `lib/features/limits/rules/domain/usecases/{rule_calendar,resolve_snapshot,rule_summary,lock_guard}.dart`
- `lib/features/limits/rules/domain/rule_sync.dart`
- `lib/features/limits/rules/data/repositories/rule_repository_impl.dart`
- `lib/features/limits/rules/presentation/{rules_cubit,rules_screen,rule_editor_screen}.dart`
- `lib/features/limits/limits.dart`
- `lib/features/limits/daily_limit/presentation/daily_limit_screen.dart` (meter-backed "used" + banner)
- `lib/features/dashboard/presentation/widgets/{rules_card,blocker_section}.dart`
- `lib/core/design_system/foundations/animated_icons.dart` (`AppIcon.rules`)
- `lib/core/navigation/{routes,app_router}.dart`, `lib/core/di/injector.dart`, `lib/main.dart`, `lib/app/app_resume_sync.dart`
- `lib/core/storage/local_store.dart` (`StoreKeys.rules`), `lib/core/utils/clock_format.dart`
- `lib/app/splash_screen.dart` (post-wipe reload of the three `..load()`-once cubits)
- `lib/core/design_system/components/{badges,selection}.dart` (`onToneColor` + the pill's width
  bound; `AppChip.semanticLabel`)
- `lib/features/catalog/domain/entities/catalog.dart` (`packagesIn` is indexed, not scanned)
- `lib/core/constants/channel_constants.dart`, `lib/core/platform_channels/engine_channel.dart`
- `lib/features/blocking/shared/domain/repositories/blocking_repositories.dart`, `lib/features/blocking/shared/data/repositories/engine_repository_impl.dart`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/{RuleEngine,LimitReconciler}.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` (`rulesJson` in its own `detoxo_rules_snapshot` file, `nextBoundaryMs`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt` (`timeTodayMs`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (`pushRules`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (`refreshRules`, `checkRuleBoundary`, the three arms, `onAppBlocked(pkg, reason)`, `onDetected(..., ruleReason)`, `reelPayload(..., reason)`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/receivers/WatchdogJobService.kt` (`checkRuleBoundary`, `reconcileLimits`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenRenderer.kt` (`unlocksAtMs` + the "Unlocks at" copy), `android/app/src/main/res/values/strings.xml`
- `android/app/build.gradle.kts` (`org.json` test dependency)
- `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/{RuleEngineTest,LimitReconcilerTest}.kt`
- `test/rules_calendar_test.dart`, `test/rules_engine_test.dart`, `test/rules_screen_semantics_test.dart`, `test/resume_sync_test.dart`
