# Daily Limit & Scheduler

The **Daily Limit** feature (`lib/features/limits/daily_limit/`) models a per-day
usage quota for short-form content, with a device-local midnight reset keyed by a
date signature. This document describes the quota model, its persistence, the
reset mechanism (the "scheduler"), and — importantly — its **current enforcement
status**, which is honest to the code: today this feature is **UI + persistence +
a lazy date-reset only**. There is no live consumption path and no gating; those
are follow-ups.

> **Status at a glance.** The quota can be set, saved, displayed, and reset at
> midnight. The `limit` value is **seeded during onboarding** (the daily-scroll
> quick-pick — see [13-onboarding-permissions.md](13-onboarding-permissions.md))
> and **read by the dashboard's screen-time ring** as that ring's max. Editing the
> limit propagates **live** to that ring (one shared cubit), and the
> limit-vs-usage comparison also drives the **day-streak** stat (§8). **Since M3 the
> limit is enforced natively** (§6): the rules snapshot carries a `daily_reel_limit`
> entry metered against native's own reel-time counter, so reel feeds block at the
> limit until midnight. The meter is `ContentCount.timeToday` — the same number the
> ring fills from — **not** `DailyLimit.consumed`, which still has no producer (§7).

---

## 1. Feature layout

Standard feature-first Clean Architecture slice under
`lib/features/limits/daily_limit/`:

| Layer | File | Role |
|-------|------|------|
| domain / entity | `domain/entities/daily_limit.dart` | `DailyLimit` value object (Equatable) + JSON + reset logic |
| domain / contract | `domain/repositories/daily_limit_repository.dart` | `DailyLimitRepository` interface (`load` / `save`) |
| data | `data/repositories/daily_limit_repository_impl.dart` | JSON persistence via `LocalStore` |
| presentation | `presentation/daily_limit_cubit.dart` | `DailyLimitCubit` — date-signature reset, `setLimit` |
| presentation | `presentation/daily_limit_screen.dart` | Slider UI, progress card, info banner |

The public barrel `lib/features/limits/limits.dart` re-exports **only** domain
entities and repository contracts (`DailyLimit` / `DailyLimitRepository`, and the
sibling `Streak` / `StreakRepository`), per the boundary rule enforced by
`tool/check_boundaries.sh`. No other feature imports the cubits or screen.

A sibling sub-feature, **`lib/features/limits/streak/`**, derives from this one:
the "days under your daily limit" streak shown on the dashboard (§8). It mirrors
this slice's layout (entity / repository / cubit).

---

## 2. The quota model — `DailyLimit`

`domain/entities/daily_limit.dart` is an immutable, `Equatable` value object with
three fields:

| Field | Type | Meaning |
|-------|------|---------|
| `limit` | `Duration` (default `Duration.zero`) | The quota cap. `zero` = **no limit set** |
| `consumed` | `Duration` (default `Duration.zero`) | Usage counted so far *today* |
| `dateSignature` | `String` (default `''`) | The local calendar day this record belongs to |

### Derived getters

```dart
bool get isExceeded => limit > Duration.zero && consumed >= limit;

Duration get remaining {
  final r = limit - consumed;
  return r.isNegative ? Duration.zero : r;
}
```

- `isExceeded` is `false` whenever no limit is set (`limit == zero`), so an unset
  quota never reports "exceeded".
- `remaining` is clamped at `Duration.zero` (never negative).

> These two getters are the intended **gate signals**, but no code currently
> reads them (verified — see §7). They exist ahead of the enforcement wiring.

### Reset logic — `refreshed()`

```dart
DailyLimit refreshed(String todaySignature) {
  if (dateSignature == todaySignature) return this;
  return DailyLimit(
    limit: limit,
    dateSignature: todaySignature,
  );
}
```

- If the stored signature already matches today, it returns `this` unchanged.
- Otherwise it constructs a **new** record that **keeps `limit`**, stamps the new
  `dateSignature`, and — by omitting `consumed` — resets it to the default
  `Duration.zero`. This is the midnight reset: the cap persists across days, the
  running total zeroes out.

Covered by `test/domain_test.dart` ("DailyLimit reset → resets consumed on a new
day"): a record with 12 min consumed against a 30 min limit, `refreshed()` to the
next day, yields `consumed == Duration.zero` and `limit == 30 min`.

### Serialization

`toJson` / `fromJson` use millisecond integers and are null-tolerant on read:

```json
{ "limitMs": 1800000, "consumedMs": 720000, "dateSignature": "06-07-2026" }
```

Missing `limitMs` / `consumedMs` default to `0`; missing `dateSignature` defaults
to `''`.

`copyWith` supports partial updates of any of the three fields.

---

## 3. Persistence — repository + `LocalStore`

`DailyLimitRepository` (domain contract) is deliberately tiny:

```dart
abstract interface class DailyLimitRepository {
  Future<DailyLimit> load();
  Future<void> save(DailyLimit limit);
}
```

`DailyLimitRepositoryImpl` (`data/`) serializes the whole entity to a single JSON
string under one key in `LocalStore` (the app's simple Dart key-value store —
**not** Hive/Drift/Room; see [09-persistence-data-model.md](09-persistence-data-model.md)):

- Store key: `StoreKeys.dailyLimit` = `'daily_limit'`
  (`lib/core/storage/local_store.dart`).
- `load()` returns `const DailyLimit()` (all-zero, empty signature) when the key
  is absent — i.e. a fresh install starts with no limit and no history.
- `save()` writes `jsonEncode(limit.toJson())`.

This record is **Dart-side**: it is not mirrored into `detoxo_engine_prefs` and
it is not part of `pushSettings` / `pushConfig`. What native sees is the
**derived** `daily_reel_limit` entry in the rules snapshot (`pushRules`, §6) —
`syncRules` reads `DailyLimitRepository.load().limit` and appends the entry when
the limit is set ([27](27-rules-engine.md) §3).

### DI wiring

`lib/core/di/injector.dart` registers only the repository:

```dart
..registerLazySingleton<DailyLimitRepository>(
  () => DailyLimitRepositoryImpl(sl()),
)
```

The **cubit is not in the locator** (get_it). It has **one shared instance**: a
**global** `DailyLimitCubit(sl<DailyLimitRepository>())..load()` registered as a
`BlocProvider` in `lib/main.dart`. Both the dashboard hero (`dashboard_tab.dart`,
which watches `limit` for its screen-time ring) **and** the editing screen
(`DailyLimitScreen`, §5) read and mutate this same instance — so a limit saved on
the screen re-emits to the dashboard **live**, with no restart.

> **Live-sync fix.** `DailyLimitScreen` previously wrapped its own inline
> `BlocProvider`, creating a *second* cubit; `setLimit` emitted only on that
> private instance and the dashboard ring went stale until relaunch. The screen
> now resolves the global instance up the tree instead, and onboarding seeds the
> limit through the same instance (`setLimit`) rather than writing the repo
> directly.

There is still **no background usage observer** — the instance never accrues
`consumed`; it exists to surface (and now live-update) the `limit` on the dashboard.

---

## 4. The "scheduler" — date-signature reset

There is **no timer, cron, `WorkManager` job, `Timer.periodic`, or alarm** behind
this feature. The "scheduler" is entirely a **lazy, on-read date comparison**.

### `todaySignature()`

```dart
// Device-local date signature for "today", e.g. "07-06-2026".
String todaySignature() => daySignature(_clock());
```

- An **instance method** on the cubit, delegating to the shared
  **`daySignature(DateTime)`** helper (`lib/core/utils/day_signature.dart`) —
  the single Dart definition of the `dd-MM-yyyy` day key (via `package:intl`),
  which must always agree with the native engine's `DateKeys` format or
  day-scoped counters drift at midnight. `StreakCubit` uses the same helper.
- `_clock` is an **injectable clock** (`DailyLimitCubit(repo, {DateTime
  Function()? clock})`, default `DateTime.now`) so tests can pin the
  midnight-reset boundary (`test/daily_limit_rollover_test.dart`). In
  production it is device-local wall-clock time — the reset boundary is the
  device's local midnight, honoring whatever the device reports (including
  manual clock changes and DST). There is no server time and no monotonic
  guard.

### When the reset fires

The comparison runs only when `DailyLimitCubit.load()` is called — now **once at
app start** (the global provider's `..load()` cascade in `lib/main.dart`), §5:

```dart
Future<void> load() async {
  final loaded = (await _repo.load()).refreshed(todaySignature());
  await _repo.save(loaded);   // persist the (possibly reset) record
  emit(loaded);
}
```

So a "day rollover" is detected and applied the **next time the app is launched**
after midnight — not at midnight itself, and not from any background process.
Because `consumed` is never populated in production (§7),
this reset is currently a no-op in practice, but the mechanism is correct and
unit-tested.

---

## 5. Presentation — cubit & screen

### `DailyLimitCubit extends Cubit<DailyLimit>`

Initial state `const DailyLimit()`; the constructor takes the optional
injectable `clock` (§4). Three methods:

| Method | Behavior |
|--------|----------|
| `load()` | Load from repo, `refreshed(today)`, save, emit. Run once at app start (global provider). |
| `setLimit(Duration limit)` | `copyWith(limit: …, dateSignature: today())`, save, emit. **Does not touch `consumed`** — changing the cap mid-day keeps the running total. |
| `addConsumed(Duration delta)` | **`@visibleForTesting` only.** Adds to `consumed`, saves, emits. **No production caller exists.** |

`setLimit` stamps today's signature so a freshly-set limit belongs to the current
day. Note the deliberate asymmetry: only `refreshed()` (a new day) clears
`consumed`; `setLimit` preserves it. A saved limit also re-pushes the rules
snapshot: `main.dart` wraps the tree in a `BlocListener<DailyLimitCubit,
DailyLimit>` that calls `RulesCubit.resync()` whenever `limit` changes.

### `DailyLimitScreen`

- Uses the **app-wide** `DailyLimitCubit` (provided in `lib/main.dart`); it no
  longer builds its own `BlocProvider`, so an edit re-emits to the dashboard live.
- **Today card** — shows `"$used of ${limit} min used"` (or `"No daily limit
  set"` when `limit == zero`) plus a `LinearProgressIndicator` of
  `used / limit` clamped to `[0,1]`, where `used` is
  **`ContentCounterCubit.state.timeToday`** — the native reel-time meter that
  enforces the limit — not `DailyLimit.consumed`.
- **Set-your-limit card** — a `Slider` from **0 to 180 minutes**, `divisions: 36`
  (→ **5-minute steps**), with a draft (`_draftMinutes`) held in local
  `setState` until the user taps **Save limit**, which calls
  `setLimit(Duration(minutes: minutes.round()))`, clears the draft, and shows a
  "Daily limit saved." **`GlassToast`** (success tone — the design system's
  toast, not a raw `SnackBar`).
- **InfoBanner** — see next section.

Reached from **Settings** (`settings_screen.dart` → `context.push(Routes.dailyLimit)`)
and the **app drawer** (`app_drawer.dart`). Route:
`Routes.dailyLimit = '/daily-limit'`, wired in `lib/core/navigation/app_router.dart`.

---

## 6. Enforcement — through the rules snapshot (M3)

The Daily Limit is enforced **natively**, without a new command, ticker or
permission, by riding the rules engine ([27-rules-engine.md](27-rules-engine.md)):

1. `syncRules` (`lib/features/limits/rules/domain/rule_sync.dart`) reads
   `DailyLimitRepository.load().limit`; when it is non-zero, `resolveSnapshot`
   appends one synthetic entry **last** in the pushed snapshot:
   `{id: "daily_reel_limit", reason: "DAILY_LIMIT", platformIds: ["*"], always:
   true, reelTimeLimitMs: <limit>}`.
2. Native `RuleEngine.blockingForPlatform(platformId, now, reelTimeTodayMs)` treats
   an entry with `reelTimeLimitMs > 0` as a **meter**: it blocks every reel feed
   (`"*"`) once `ContentCounter.timeTodayMs()` — the counter's own day-keyed reel
   time, the number the dashboard ring fills from — has reached the limit. The
   read happens only after a detector match, never per raw event.
3. The detector loop asks the rules engine **before** the plan's allow checks, so
   the limit trips even under One Reel / Unblock / Conscious allowance:
   `onDetected(..., ruleReason = "DAILY_LIMIT")` bounces the reel and raises the
   wall with **"Your daily limit is used up"** ([25](25-block-screen.md)). The
   `blocked` event carries `reason: "DAILY_LIMIT"`.
4. Midnight needs no Dart: the counter's `timeTodayMs` rolls with its day key, so
   the meter reads zero again and the block lifts. `main.dart` re-syncs the
   snapshot whenever the limit changes (a `BlocListener<DailyLimitCubit>`), and
   the rules screen pins a **Daily reel limit** row showing "used / limit".

**Semantics.** The limit is a reel-time limit — it blocks reel *feeds* (every
platform Detoxo detects), not whole apps, which is exactly what the ring
measures. It sits below the Pause gate like every rule: a Pause lifts it. It
depends on the reel counter: with counting **off**, `timeTodayMs` does not
accrue and the limit cannot trip — the screen's banner says so
(`ContentCount.enabled == false` → "Reel counter is off").

The screen's banner now reads: *"When today's reel time reaches the limit,
Detoxo blocks every reel feed until midnight. A Pause lifts it like any other
block."*

### The daily limit and a per-target unblock (M8)

The synthetic meter entry is `always: true` with `platformIds: ["*"]` and is
**not** strict, so a `REEL` grant on one feed lifts it — **for that feed only**,
for the length of the grant. That is the right reading of the gesture: "let me
into Instagram Reels for 15 minutes" should mean what it says even on a day
whose budget is spent, and every other feed stays blocked until midnight.

Nothing else about the limit changes. The grant expires natively, the meter
keeps accruing throughout (the awareness counter runs above the whole block
branch, so a granted reel is still counted), and the limit re-arms on its own.
Full mechanism in [31-locked-rules-and-unblock.md](31-locked-rules-and-unblock.md) §2.

**Still true:** `DailyLimit.consumed` has no producer — `addConsumed` remains
`@visibleForTesting` with no production caller — and `isExceeded` / `remaining`
have no reader. The entity's `consumed` field is legacy shape, not the meter;
a cleanup that drops it is a schema touch and deliberately out of scope here.

---

## 7. Quick verification notes

- Native reference check: `grep -rn "dailyLimit\|consumedMs\|dateSignature\|daily_limit" android/` → **no matches** — native knows the limit only as the `daily_reel_limit` entry's `reelTimeLimitMs` in the pushed rules snapshot (`grep -rn reelTimeLimitMs android/` → `RuleEngine.kt`).
- Consumption writers: only `DailyLimitCubit.addConsumed` (`@visibleForTesting`); no external caller (`grep addConsumed lib/ android/` → only the definition). The enforcement meter is the content counter's `timeTodayMs`, not `consumed`.
- Gate readers: no reader of `isExceeded` / `remaining` outside the entity and its test. (The dashboard ring reads the raw `limit` field for display; the gate is native — §6.)
- Seeding / display: `limit` is seeded by `onboarding_screen.dart` via the shared `DailyLimitCubit.setLimit` (routed through the global provider so onboarding's pick shows on the dashboard live), and read by `dashboard_tab.dart` from that same instance.
- Test coverage: `test/domain_test.dart` exercises `refreshed()` (day rollover clears `consumed`, preserves `limit`). No test drives an end-to-end enforcement path (there is none).

> **Naming caution:** do not confuse this feature's `DailyLimit` with
> `AppBlockEntry.dailyLimitMinutes` in the sibling *app_blocker* feature
> (`lib/features/limits/app_blocker/domain/entities/app_block_entry.dart`) — that
> is a separate per-app field on the app-block list and is unrelated to this
> global daily quota. The `DAILY_LIMIT_HERO` emoji band
> (`emoji_band.dart` / `assets/content/daily_limit_emoji_bands.json`) is likewise
> just decorative content, not enforcement.

---

## 8. Under-limit streak — `Streak`

The dashboard hero's second stat pill is a **day streak**: the number of
consecutive days the user has stayed **under their daily limit** (it replaced the
old raw "blocked today" count). It lives in the sibling sub-feature
`lib/features/limits/streak/`, mirrors this feature's slice
(entity / repository / cubit), and persists to its own `LocalStore` key
`StoreKeys.streak = 'daily_limit_streak'`.

### Model — `Streak { base, lastDay, todayFailed }`

| Field | Meaning |
|-------|---------|
| `base` | Consecutive under-limit days completed **before** today |
| `lastDay` | `dd-MM-yyyy` signature of the last day the streak was evaluated |
| `todayFailed` | Whether today has broken the streak (limit exceeded, or no limit set) — sticky within a day |

`int get count => base + (todayFailed ? 0 : 1)` — today counts optimistically
while still under the limit and drops the +1 the moment the limit is exceeded; the
default state (`base:0, lastDay:'', todayFailed:true`) reads `0`.

### Evaluation — `StreakCubit`

A **global** `StreakCubit(sl<StreakRepository>())..load()` is registered in
`lib/main.dart`. The dashboard hero (`dashboard_tab.dart`) — which already computes
`underLimit = hasLimit && spent < limit` for the ring — calls
`observe(now, underLimit)` in a post-frame callback each build (bloc skips equal
states, so re-observes are cheap no-ops), but **only once every input is real**:
the counter snapshot has landed (`ContentCount.loaded`), the limit has loaded
(`DailyLimit.dateSignature` non-empty — `load()` always stamps today's), and
counting is on (`ContentCount.enabled`; with it off usage-time isn't measured,
so a zero must not earn a day — and the streak pill shows "—", since the stored
streak isn't reconciled until counting resumes, when a skipped gap resets it).
`StreakCubit.observe` additionally ignores calls until its own `load()` has
emitted. Before these guards the hero's first build
observed the unloaded defaults — no limit → "today failed", and the empty
`Streak()` advanced and **persisted** over the real one — which wiped or froze
the streak on cold starts. The pure transition (`StreakCubit.advance`,
`@visibleForTesting`) is:

- **same day** → a failure is sticky (`todayFailed |= !underLimit`);
- **consecutive day** → carry yesterday's committed streak forward if it qualified,
  else reset (`base = lastDay==yesterday && !todayFailed ? count : 0`);
- **gap / first run** → start fresh.

`observe` computes "yesterday" with **calendar arithmetic** —
`DateTime(now.year, now.month, now.day - 1)` — **not**
`subtract(Duration(days: 1))`: that subtracts 24 h of absolute time, which on
the day after a DST spring-forward (a 23 h day) lands two calendar days back
and silently reset the streak once a year. Day signatures come from the shared
`daySignature` helper (§4).

Because "under limit" is only observed while the app is open, a fully skipped day
resets the streak — standard streak behaviour, and consistent with the lazy
date-rollover used for the limit itself (§4). Like the limit, it is a
**display-only** metric — it never gates or blocks. Covered by
`test/streak_test.dart` (including the DST spring-forward case).

---

> **Cap note.** The synthetic daily-reel-limit entry is appended *after* the user's rules in the
> pushed snapshot, so the native parser caps at `MAX_ENTRIES = 51` (`maxRules` + 1). Capping at 50
> truncated exactly this entry at the 50-rule cap and silently stopped enforcing the Daily Limit
> while its UI still showed it set ([27](27-rules-engine.md) §5).

## Source files

- `lib/features/limits/daily_limit/domain/entities/daily_limit.dart`
- `lib/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart`
- `lib/features/limits/daily_limit/data/repositories/daily_limit_repository_impl.dart`
- `lib/features/limits/daily_limit/presentation/daily_limit_cubit.dart`
- `lib/features/limits/daily_limit/presentation/daily_limit_screen.dart` (uses the app-wide cubit; no inline provider; "used" from `ContentCounterCubit.timeToday`)
- `lib/features/limits/rules/domain/rule_sync.dart`, `lib/features/limits/rules/domain/usecases/resolve_snapshot.dart` (the `daily_reel_limit` snapshot entry — §6)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/RuleEngine.kt`, `ContentCounter.kt` (`timeTodayMs`) — the native meter (§6)
- `lib/features/limits/streak/domain/entities/streak.dart` (§8)
- `lib/features/limits/streak/domain/repositories/streak_repository.dart`
- `lib/features/limits/streak/data/repositories/streak_repository_impl.dart`
- `lib/features/limits/streak/presentation/streak_cubit.dart`
- `lib/core/utils/day_signature.dart` (shared `dd-MM-yyyy` day-key helper — must agree with native `DateKeys`)
- `lib/features/limits/limits.dart`
- `lib/core/storage/local_store.dart` (`StoreKeys.dailyLimit = 'daily_limit'`, `StoreKeys.streak = 'daily_limit_streak'`)
- `lib/core/di/injector.dart` (`DailyLimitRepository` + `StreakRepository` registrations)
- `lib/core/navigation/routes.dart` / `lib/core/navigation/app_router.dart` (`Routes.dailyLimit = '/daily-limit'`)
- `lib/features/settings/presentation/settings_screen.dart` / `lib/features/dashboard/presentation/widgets/app_drawer.dart` (entry points)
- `lib/features/onboarding/presentation/onboarding_screen.dart` (seeds `limit` on finish via the shared `DailyLimitCubit.setLimit`)
- `lib/main.dart` (global `DailyLimitCubit` + `StreakCubit` providers)
- `lib/features/dashboard/presentation/dashboard_tab.dart` (reads `limit` for the ring; observes the under-limit streak and reads its `count`)
- `lib/features/dashboard/presentation/widgets/command_center_card.dart` (the day-streak stat pill)
- `test/domain_test.dart` (`DailyLimit reset` group) / `test/streak_test.dart` (streak transitions incl. the DST spring-forward day) / `test/daily_limit_rollover_test.dart` (cubit midnight reset via the injected clock)
