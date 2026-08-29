# EVO-028 — Tell the user when a rule block lifts, on the wall itself

- Status: done (in the working tree; stamp the commit hash on commit)
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/limits/rules`, native `overlay/` + `accessibility/`
- Commit: 190042a
- Date: 2026-09-03
- Effort: S

## Why

The wall names the reason and stops there. `android/app/src/main/res/values/strings.xml:30`
is the whole story a schedule tells:

```xml
<string name="wall_reason_schedule">Blocked by a schedule</string>
```

The release time is already in the engine's hands — `RuleEngine.Entry.windows` holds the
absolute `[from, until]` pair that `isActive(now)` just matched
(`engine/RuleEngine.kt:39-47`) — and the payload already has a convention for optional
stat lines: `-1` means "not applicable, skip the line"
(`overlay/BlockScreenRenderer.kt:50-56`, EVO-027's `opensToday`). So the data and the
rendering slot both exist; nothing joins them.

## Expected user impact

A schedule wall becomes "Blocked by a schedule · Unlocks at 5:30 PM" and a spent daily
limit becomes "Your daily limit is used up · Resets at midnight". That converts a
dead-end into a decision the user can make ("fine, I'll come back after work") instead of
a wall they retry against. It serves the differentiator directly — the product's claim is
a *firm, friendly nudge exactly when you need it*
(`docs/info_docs/01-product-overview.md`, §The solution), and a nudge that won't say how
long it lasts is firm without being friendly.

## Technical complexity

Native only, and **no wire change**: `BlockScreenPayload` travels from the accessibility
service to the overlay renderer inside the process, never over the MethodChannel. One new
field with the established `-1` default, one branch in the reason copy, one new string
resource. The 12/24-hour rendering uses `android.text.format.DateFormat.getTimeFormat(context)`
so it follows the device setting like the Dart side now does
(`lib/core/utils/clock_format.dart`).

## Performance impact

None on the hot path. The value is read once, at the moment the wall is raised — the
window end is already loaded on the matched `Entry`, so it is a field read, not a lookup.
Formatting happens in the overlay renderer, which already runs off the detection path.

## Business value

Strengthens the intervention loop rather than decorating it: the wall is the single most
visible surface in the product (`docs/info_docs/01-product-overview.md`, §Reel & Short
blocking, which lists the wall's three ways out). Also removes a support question — "why
is it blocked and when does it stop?" — that the FAQs currently answer only in the app's
own docs (`docs/info_docs/04-faqs.md`).

## Rejected alternative

A countdown that ticks on the wall ("unlocks in 42:10"), reusing EVO-025's countdown
machinery. Rejected: it invites the user to sit and watch the timer, which is the
opposite of the behaviour the product is trying to produce, and it costs a repeating
invalidate on an overlay that is deliberately static.

## Rollback

Delete the field, the branch and the string. No storage, no wire, no manifest change, so
a revert is a pure code revert with nothing left behind.

## Implementation Plan

### Current state

`android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenRenderer.kt:50-56`

```kotlin
    val blockReason: String,          // PLAN | APP_BLOCK | WEB_RULE | ADULT | DAILY_LIMIT | SCHEDULE
    val plan: String = "",            // BLOCK_ALL | CURIOUS | ONE_REEL | "" (no chip)
    val allowance: Int = 1,           // the armed One Reel / Unblock count
    val todayCount: Int = -1,
    val allowanceLeft: Int = -1,
    val bankMs: Long = -1L,
    val opensToday: Int = -1,         // foreground transitions since midnight; filled late by the overlay
```

`overlay/BlockScreenRenderer.kt:413-414`

```kotlin
                BlockScreenPayload.REASON_DAILY_LIMIT -> res.getString(R.string.wall_reason_daily_limit)
                BlockScreenPayload.REASON_SCHEDULE -> res.getString(R.string.wall_reason_schedule)
```

`engine/RuleEngine.kt:39-47` — `isActive` scans `windows` but discards which pair matched.

### Target state

- `RuleEngine.Entry` gains `fun activeUntil(now: Long): Long` returning the `until` of the
  window containing `now`, or `0L` when `always` is set or nothing matches.
- `BlockScreenPayload` gains `val unlocksAtMs: Long = -1L`, carried through `fromMap`
  exactly like `bankMs`.
- The service passes `rule.activeUntil(now)` when it raises a rule wall (both the package
  arm and the reel arm).
- The reason line appends, only when `unlocksAtMs > 0`:
  - `SCHEDULE` → `R.string.wall_reason_schedule_until` — `"Blocked by a schedule · Unlocks at %1$s"`
  - `DAILY_LIMIT` → `R.string.wall_reason_daily_limit_until` — `"Your daily limit is used up · Resets at %1$s"`
- Time rendered with `android.text.format.DateFormat.getTimeFormat(context)` so it honours
  the device's 12/24-hour setting.

### Repo conventions to follow

- `-1` (or `0`) means "skip this line" — never render a zero (`BlockScreenRenderer.kt:41-42`).
- Strings live in `res/values/strings.xml`, never inline in Kotlin.
- `RuleEngine` stays Android-free: `activeUntil` returns a `Long`, and all formatting
  happens in the renderer. Its JVM test must keep passing without `android.jar`.
- New pure logic gets a JUnit4 case in
  `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/RuleEngineTest.kt`.

### Steps

1. Add `activeUntil(now)` to `RuleEngine.Entry` beside `isActive`.
2. Add the `RuleEngineTest` case: overlapping windows return the one containing `now`; an
   `always` entry returns `0`.
3. Add `unlocksAtMs` to `BlockScreenPayload` + `fromMap`.
4. Populate it at the two rule-wall sites in `DetoxoAccessibilityService.kt`.
5. Add the two strings; branch the reason copy in `BlockScreenRenderer.kt`.
6. Update `docs/code_docs/25-block-screen.md` and `27-rules-engine.md`.

### Boundaries

Do not touch the plan / app-block / web-rule / adult reason branches — this is additive to
the two rule reasons only. Do not add a channel key. Do not make `RuleEngine` import
`android.*`. If the code at the cited lines has drifted from the Commit stamp above, STOP
and report — do not improvise.

### Validation

- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (`RuleEngineTest`)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS" intact in
      wire/code, "Conscious" in UI strings
- [ ] Production readiness: state survives process death + reboot; permission-revoked path
      handled; works offline; no new manifest permission; Crashlytics covers new failure paths
- [ ] Native touched → manual device sanity: a 2-minute schedule shows "Unlocks at HH:MM"
      and the time is correct in both 12- and 24-hour device settings; a spent daily limit
      shows "Resets at midnight"; service reconnects after toggling accessibility
- [ ] `/docs-sync` run; mapped docs updated
