# EVO-030 — Strict rules: a rule a Pause cannot lift

- Status: done (in the working tree; stamp the commit hash on commit)
- Tier: 2 (enhancement) — new user-facing capability + a stored field
- Feature: `lib/features/limits/rules`, native `accessibility/` + `engine/RuleEngine.kt`
- Commit: 190042a
- Date: 2026-09-03
- Effort: S

## Why

Rule blocks sit **below** the pause gate — a deliberate M3 decision, documented in the
screen's own InfoButton ("A Pause lifts rules the way it lifts reel blocking; App Blocker
locks stay on") and enforced at
`android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`:

```kotlin
        if (nowMs < pausedUntil) return
```

That is the right default — a schedule you set for yourself should yield to "I need this
for two minutes". But it means **every** rule is two taps from being suspended, including
the ones a user sets precisely because they do not trust themselves at 1 a.m. The App
Blocker already has the stricter behaviour (its arm sits above the gate); rules have no
way to opt into it.

## Expected user impact

A per-rule "Strict" switch in the editor. A strict rule keeps enforcing through a Pause
and an emergency pass, and says so on the wall. Non-strict stays the default, so nothing
changes for anyone who does not go looking.

This lands squarely on the product's stated differentiator. The comparison table's last
row is *"Easy to ignore or turn off"* vs *"Optional PIN lock and uninstall protection keep
future-you honest"* (`docs/info_docs/01-product-overview.md`, §Why Detoxo is different),
and the PIN section frames the whole idea as *"a real commitment device for future-you"*.
Strict rules are that idea applied to time, and they compose with the PIN: a strict rule
behind a PIN is genuinely hard to undo in a weak moment, which is the point.

## Technical complexity

Small and entirely additive:

- One stored field on the rule document (`strict: true`), additive to the existing
  vocabulary, so old documents read as non-strict and older builds ignore it.
- One snapshot field, mirrored in `RuleEngine.Entry`.
- One branch: the rules arm currently sits after the pause gate; a strict entry must be
  consulted **before** it. That means splitting the arm in two — a strict pass above the
  gate, the existing pass below — not moving it.
- One editor toggle, one wall string.

No new channel key, no new permission, no migration.

## Performance impact

The strict pass costs one extra `hasStrictRules()` volatile read per event for users with
no strict rule — the same shape as the `hasPackageRules()` gate the audit just added, and
false for everyone by default. For users with one, it is the same set lookup plus window
compare the arm already does, just evaluated earlier.

## Business value

Retention and the store-listing story. The listing already sells commitment
(*"Make it stick"*, §Long description) and this is the missing half: today the commitment
devices are all about protecting *Detoxo's settings*, not about protecting the *blocks*.
It also answers the most predictable review complaint about any blocker — "I just paused
it" — with a feature rather than a shrug.

## Rejected alternative

A global "strict mode" switch in Settings that makes the Pause button refuse while any
rule is active. Rejected: it is coarse (all rules or none), it breaks the Pause button's
contract in a way that reads as a bug rather than a choice, and it puts the setting far
from the rule it governs. Per-rule keeps the decision next to the thing being decided,
and keeps the Pause button honest everywhere else.

## Rollback

Delete the field, the snapshot key, the strict pass and the toggle. Stored documents keep
a `strict` key that nothing reads — harmless and forward-compatible if it is ever
restored. No one-way door: no key rename, no manifest change, no migration.

## Implementation Plan

### Current state

`android/.../accessibility/DetoxoAccessibilityService.kt` — one arm, below the gate:

```kotlin
        if (nowMs < pausedUntil) return

        // Rules: a schedule window or a spent daily limit covering this app
        // (the pushRules snapshot). Below the pause gate by design — see the
        // ruleEngine field. Foreground-anchored like the App Blocker arm above,
        // and before the throttle so a WINDOW_STATE_CHANGED is never swallowed.
        // Gated on hasPackageRules, NOT hasAnyRules: a user with only a global
        // Daily Limit has a (meter) entry and no package rule at all, and this
        // arm runs above the throttle on essentially every foreground event.
        if (ruleEngine.hasPackageRules() &&
```

`lib/features/limits/rules/domain/entities/rule.dart` — `Rule.toJson` writes the
plan-doc vocabulary (`enabledState`, `activation`, `timeLimit`, `openLimit`).

`lib/features/limits/rules/domain/entities/rule_snapshot.dart` — `SnapshotEntry.toJson`
is the mirror contract with `RuleEngine.parse`.

### Target state

- `Rule` gains `final bool strict` (default `false`), read type-tolerantly via the
  existing `_str`/`_int` helpers' sibling for bools, written as `"strict": true` only
  when set.
- `SnapshotEntry` gains `strict`; `RuleEngine.Entry` mirrors it;
  `RuleEngine.hasStrictRules()` computed at parse, beside `hasPackageRules`.
- `RuleEngine.blockingForPackage(pkg, now, strictOnly: Boolean = false)` — when
  `strictOnly`, only strict entries match.
- The service gains a strict pass **immediately above** `if (nowMs < pausedUntil) return`,
  gated on `hasStrictRules()`; the existing pass below is unchanged.
- Wall copy: `R.string.wall_reason_schedule_strict` — "Blocked by a strict schedule".
- Editor: an `AppToggleTile` "Strict — a Pause won't lift this", with an `InlineHint`
  spelling out that it also survives an emergency pass.
- The rules screen's InfoButton copy is updated; it currently states the opposite
  unconditionally.

### Repo conventions to follow

- UI from `lib/core/design_system/components/` — `AppToggleTile` and `InlineHint`, the
  same pair the editor already uses.
- The rule document's vocabulary is additive; unknown keys must never throw
  (`Rule.fromJson` is null- and type-tolerant as of this run's row 5).
- `RuleEngine` stays Android-free; the new gate is a `Boolean` computed at parse.
- Copy says "Conscious", never "curious"; the wire token is untouched by this change.

### Steps

1. `Rule.strict` + `copyWith` + `toJson`/`fromJson` (tolerant read) + `props`.
2. `SnapshotEntry.strict` + `toJson`; set it in `resolveSnapshot` for both schedules and
   spent limits. Extend the mirror-contract test.
3. `RuleEngine`: `Entry.strict`, `Snapshot.hasStrictRules`, `strictOnly` parameter.
   Add `RuleEngineTest` cases: strict-only matching, and a non-strict entry ignored when
   `strictOnly`.
4. Service: strict pass above the pause gate; pass the reason through to the wall.
5. Editor toggle + hint; InfoButton copy; `RuleSummary` mentions "Strict" in `describe`.
6. `test/rules_engine_test.dart`: a strict rule round-trips, and appears in the snapshot
   with `strict: true`.
7. Docs: `27-rules-engine.md` (pause semantics section), `03-detection-engine.md` (guard
   order), `05-plans-pause-conscious.md` (what a Pause now does and does not lift),
   `info_docs/02-feature-walkthroughs.md` §14, `info_docs/04-faqs.md`.

### Boundaries

Do NOT move or weaken the existing below-the-gate pass — strict is an addition, not a
reversal of the M3 decision. Do NOT touch the App Blocker arm. Do NOT make strict the
default, and do NOT apply it to the global Daily Limit's meter entry (that is a different
feature with its own switch). If the code at the cited lines has drifted from the Commit
stamp above, STOP and report — do not improvise.

### Validation

- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (Dart + `RuleEngineTest`)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS" intact in
      wire/code, "Conscious" in UI strings
- [ ] Production readiness: a strict rule survives process death and reboot; still
      enforces with the accessibility service freshly reconnected; works offline; no new
      manifest permission
- [ ] Native touched → manual device sanity: start a Pause, confirm a strict rule still
      blocks and a non-strict one does not; confirm an App Blocker lock is unaffected;
      service reconnect, bubble drag/snap/tap, home-widget refresh
- [ ] `/docs-sync` run; mapped docs updated
