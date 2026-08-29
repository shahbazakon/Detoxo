# EVO-023 — Run the native JVM tests in the precommit gate

- Status: done (implemented on `sensitive_protection`, commit pending)
- Tier: 2 (tooling / gate change) — approved by the user in-session ("i
  approved all", 2026-08-29)
- Feature: tool (`tool/dev.sh`; `tool/qa.sh functional` delegates to it)
- Commit: 424a8f6 (proposal-time HEAD; implementation uncommitted at authoring)
- Date: 2026-08-29
- Effort: S

## Why
EVO-020 added the repo's first native unit tests — `ReelTrackerTest`, 20
scenarios at the time (23 after the EVO-020 detour fixes and EVO-024) for the
state machine that decides whether the counter is honest —
but `bash tool/dev.sh precommit` (and therefore `qa.sh functional`, the QA
report's Layer 1) ran format + analyze + `flutter test` + boundaries only
(`tool/dev.sh:50`). A regression in the counting rule was caught by memory, not
by the gate.

## Expected user impact
Indirect: the counting rule — the product's headline number — cannot regress
silently between releases.

## Technical complexity
Shell only. `native_tests()` in `tool/dev.sh` resolves a JDK 17+ (`$JAVA_HOME`,
else macOS `java_home -v 17+`, else the Homebrew `openjdk@17` keg) and runs
`./gradlew -q :app:testDebugUnitTest`; without a JDK it warns and skips so the
gate never fails on a host that can't run Gradle. Wired into `precommit` and
`validate`.

## Performance impact
+~30–60 s per precommit on a warm Gradle daemon (the Flutter Dart compile is
part of the Gradle graph); nothing at runtime.

## Business value
Reliability of the intervention loop's awareness half — see
`docs/info_docs/01-product-overview.md`.

## Rejected alternative
CI — there is none (AUDIT.md lists "No CI" as its own Tier-2 item); the local
gate is the only gate today, so that is where the tests must run.

## Rollback
Remove `native_tests` from the two `dev.sh` targets.

## Implementation Plan (as shipped)
1. `tool/dev.sh` — `native_tests()`; `t_precommit` / `t_validate` call it after
   `flutter test`.
2. Doc 23 — everyday-loop section.

### Validation
- [x] `bash tool/dev.sh precommit` runs the native tests (23/23 green)
- [x] Without a JDK the step warns and the gate still passes
