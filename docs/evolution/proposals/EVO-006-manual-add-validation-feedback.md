# EVO-006 — Validate and give feedback on manual adds (protected apps + app blocker)

- Status: done
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/features/protected_apps + lib/features/limits/app_blocker + lib/core/utils
- Commit: 5052d20 (proposed) · implemented 2026-08-14 on the working tree above f2941b5
- Date: 2026-08-13 · Approved & implemented: 2026-08-14
- Effort: S

> **Amendment (2026-08-14, at approval).** Scope extended with two audit findings from
> the installed-app picker evolution run: (a) the picker's new unconditional success
> toast made the silent no-op *actively affirmative* — "Protected X" for an add that
> never landed — worse than the old dialog's silence; (b) `AppBlockCubit.add` has the
> identical silent no-op (empty/dup, plus the sensitive-catalog refusal added later),
> which the original proposal didn't cover. Both are fixed by the same mechanism.
> **Correction to the original text:** "lowercase reverse-DNS pattern" is wrong —
> `com.Slack` is a real application id, so the validator preserves case and accepts
> `[A-Za-z]`-led segments; input is trimmed, never lowercased.

## Why
The add dialog (`protected_apps_screen.dart`, `_showAdd`) accepts any string as a
package name — garbage, spaces, uppercase, arbitrary length — and persists + pushes it
natively. And `ProtectedAppsCubit.addManual` returns silently for empty, duplicate, and
catalog packages while the dialog pops unconditionally, so a no-op looks identical to
success. A user who typos `com.hdfc.bank` believes their bank is protected when the
entry can never match a real event package.

## Expected user impact
The add flow tells the truth: invalid package shapes are rejected inline, and duplicate/
already-covered adds get a `GlassToast` ("Already protected automatically"). Protects the
credibility of the feature's core promise; peripheral to the intervention loop itself.

## Technical complexity
Dart-only. Package-shape validation (lowercase reverse-DNS pattern, length cap) in the
cubit (static `@visibleForTesting` validator per repo idiom), an add-result enum
consumed by the dialog, `GlassToast` feedback (`design_system/components/overlays.dart`).
Inline-validation exemplar: `_SiteSheet` in `web_block_screen.dart`. No channel or
storage changes.

## Performance impact
None — dialog-time only; nothing on the accessibility hot path.

## Business value
Trust in the privacy feature (product overview: "keeps what you see and do private").
A silent no-op that looks like success is the kind of papercut that produces 1-star
"doesn't work" reviews.

## Rejected alternative
Validating only in the UI layer (TextField formatters) — leaves `addManual` accepting
garbage from any future call site; the cubit is the right trust boundary.

## Rollback
Revert the commit; no persisted-format changes (invalid entries were never written under
this proposal, and previously written ones remain readable).

## Implementation Plan (as built, 2026-08-14)

### What shipped
- `lib/core/utils/package_name.dart` — `isValidPackageName`: two-plus dot-separated
  segments, `[A-Za-z]`-led, `[A-Za-z0-9_]` inside, ≤255 chars. Case preserved.
  Test: `test/package_name_test.dart`.
- `ProtectedAppsCubit.addManual` → `Future<ProtectedAddResult>`
  (`added | invalid | duplicate | alreadyCovered`; enum in
  `domain/entities/protected_app.dart`). Invalid input never persists.
- `AppBlockCubit.add` → `Future<AppBlockAddResult>`
  (`added | invalid | sensitive | duplicate`; enum in
  `domain/entities/app_block_entry.dart`). Keeps the sensitive-catalog refusal.
- Both screens aggregate batch results: success toast counts only landed adds
  ("Protected 2 of 3 apps"); an all-refused batch shows the first refusal's reason as
  an `AppTone.warning` toast ("Already protected automatically." / "Sensitive app —
  Detoxo never blocks it." / "That doesn't look like a package id."). Blocker success
  copy is **"Added …"**, not "Blocked …" — custom locks record intent, enforcement is
  the documented follow-up (doc 06).
- The picker's manual form (core/widgets/app_picker_sheet.dart) blocks `unavailable`
  packages inline and configures the package field like the web-blocker's host field
  (`keyboardType: TextInputType.url`, `autocorrect: false`).
- Tests: results pinned in `test/protected_apps_test.dart` (addManual test) and
  `test/app_block_cubit_test.dart` (incl. `com.Slack` casing).

### Rejected alternative (unchanged from proposal)
UI-layer-only validation — the cubits are the trust boundary.
