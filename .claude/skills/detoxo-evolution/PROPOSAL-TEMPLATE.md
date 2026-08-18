# Evolution Proposal & Plan Formats

Two formats. **Template A** is a Tier-2 enhancement proposal — one file per proposal under
`docs/evolution/proposals/EVO-NNN-short-slug.md` (`NNN` monotonic, zero-padded, never
reused). **Template B** is the lightweight note for a batch of approved Tier-1 fixes —
it lives in the conversation and the commit message, not the ledger.

**The executor may have zero context and zero taste.** Inline everything: exact paths,
verbatim current-code excerpts, exact target values, the repo exemplar to imitate. Never
write "as discussed above."

---

## Template A — Tier-2 enhancement proposal

```markdown
# EVO-NNN — <imperative title, e.g. "Add weekly reel-count trend to dashboard">

- Status: proposed          <!-- proposed | approved | done | rejected -->
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: <lib/features/<x> and/or native package>
- Commit: <git rev-parse --short HEAD at proposal time>
- Date: YYYY-MM-DD
- Effort: S | M | L         <!-- S ≤ half day, M ≤ 2 days, L > 2 days -->

## Why
<The gap, with file:line evidence. What exists today and why it falls short.>

## Expected user impact
<Observable change for the user. Tie it to the product differentiator — the
in-the-moment intervention loop and the plans model (Block All / Conscious /
One Reel / Unblock / Pause) — or say honestly that it's peripheral polish.>

## Technical complexity
<Layers touched: Dart / native Kotlin / platform channel / storage schema /
manifest / assets. New channel keys or storage keys are contract changes — name them.>

## Performance impact
<Frame budget, traversal budget, battery, startup. "None" must be argued, not asserted —
e.g. "runs only on screen open, not on the accessibility hot path.">

## Business value
<Scored against docs/info_docs/01-product-overview.md: does it strengthen the
differentiator, retention, or store-listing story? Cite the section.>

## Rejected alternative
<The other strategy considered and one line on why it lost.>

## Rollback
<How to revert cleanly. Flag any one-way doors: storage-schema migrations,
persisted-key renames, manifest permission additions.>

## Implementation Plan
<!-- Fill this section ONLY once Status: approved. -->

### Current state
<Verbatim code excerpts with `path:line` for every site the change touches.>

### Target state
<The exact end state. Every value spelled out — widget names, channel keys,
storage keys, copy text ("Conscious", never "curious" in UI).>

### Repo conventions to follow
<Exemplar file:line to imitate. Defaults: cubit in presentation/ with plain-entity
state; pure logic as a static @visibleForTesting method (see StreakCubit.advance,
lib/features/limits/streak/presentation/streak_cubit.dart); repos/services in
lib/core/di/injector.dart, cubits NOT in get_it; UI from
lib/core/design_system/components/; feature reachable only via its barrel.>

### Steps
<Numbered; one concrete edit per step. Include `dart run build_runner build
--delete-conflicting-outputs` as a step if freezed/json models change.>

### Boundaries
<Do-NOT-touch list. Plus: "If the code at the cited lines has drifted from the
Commit stamp above, STOP and report — do not improvise.">

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern (bloc_test/mocktail)
- [ ] Invariants grep clean: names Detoxo/errorxperts only; `curious`/"CURIOUS"
      intact in wire/code, "Conscious" in UI strings
- [ ] Production readiness: state survives process death + reboot
      (BootReceiver/ConfigStore path) · permission-revoked path handled ·
      works offline · no new manifest permission (else it's called out in the
      proposal header) · Crashlytics covers new failure paths
- [ ] Native touched → manual device sanity list: service reconnects after
      toggling accessibility, bubble drag/snap/tap, home-widget refresh
- [ ] `/docs-sync` run; mapped docs updated
```

---

## Template B — Tier-1 batch-fix note

No ledger file. When the user approves findings rows ("fix 1, 3, 4"), restate the batch
before touching code, then implement as one commit-sized unit:

> **Fixing #1, #3, #4** — <one line each: location → root-cause fix>. Diff scope:
> <files>. Anything beyond this scope that turns up mid-fix gets reported, not fixed.

After implementing, run the same Validation checklist as Template A (precommit,
baseline, invariants grep, `/docs-sync`). A Tier-1 batch that grows past 5 files or
150 lines goes back to the approval gate re-scoped, per SKILL.md guardrails.
