# Evolution Backlog

Ledger for `/detoxo-evolution` (see `.claude/skills/detoxo-evolution/SKILL.md`).
Lifecycle: `proposed` → `approved` → `done` (commit-stamped) | `rejected` (kept
forever — the settled-decisions memory). IDs are monotonic and never reused.

| ID | Title | Feature | Tier | Status | Effort | Proposed | Decided |
|---|---|---|---|---|---|---|---|
| EVO-001 | Smart Auto Lock for the PIN lock | access_protection | 2 | done | M | 2026-08-07 | 2026-08-07 |
| EVO-002 | Harden the PIN KDF (PBKDF2, transparent re-hash) | access_protection | 2 | proposed | S | 2026-08-08 | — |
| EVO-003 | Commitment delay on disabling the PIN lock | access_protection | 2 | proposed | M | 2026-08-08 | — |
| EVO-004 | "While you were away" failed-attempt notice | access_protection | 2 | proposed | S | 2026-08-08 | — |
| EVO-005 | Exclude sensitive stores from Android backup | protected_apps | 2 | proposed | S | 2026-08-13 | — |
| EVO-006 | Validate + give feedback on manual adds (protected + blocker) | protected_apps, app_blocker | 2 | done | S | 2026-08-13 | 2026-08-14 |
| EVO-007 | Installed-app picker (labels + icons) for manual adds | protected_apps, app_blocker, core | 2 | done | M | 2026-08-13 | 2026-08-14 |
| EVO-008 | Real device icons on saved Block/Protected rows | app_blocker, protected_apps | 2 | done | S | 2026-08-14 | 2026-08-14 |
| EVO-009 | "Suggested" section at the top of the add-app picker | core (picker) + native | 2 | proposed | M | 2026-08-14 | — |
| EVO-010 | Refresh affordance in the add-app picker | core (picker) | 2 | done | S | 2026-08-14 | 2026-08-14 |
| EVO-011 | "Blocked by Detoxo" toast at the block moment | web_blocker (native) | 2 | done | S | 2026-08-17 | 2026-08-17 |
| EVO-012 | Per-site pause, activating dormant pausedUntil | web_blocker + native | 2 | done | M | 2026-08-17 | 2026-08-17 |
| EVO-013 | Honest protection status when OS kills the service | blocking/engine + native | 2 | done | S | 2026-08-17 | 2026-08-17 |
| EVO-014 | Render permission/service `unknown` states truthfully | permissions, dashboard, design_system | 2 | done | S | 2026-08-27 | 2026-08-27 |
| EVO-015 | Anchor the PIN lockout to the monotonic clock | access_protection + native | 2 | done | M | 2026-08-27 | 2026-08-27 |
| EVO-016 | Narrow the accessibility event mask to the 3 used types | native res/xml | 2 | done | S | 2026-08-27 | 2026-08-27 |
| EVO-017 | Compile the 18+ list from a JSON source (scrape folded in) + block adult TLDs | web_blocker + native asset + tool | 2 | done | S | 2026-08-28 | 2026-08-28 |
| EVO-018 | Count adult-list blocks without naming the host | web_blocker (native) | 2 | done | S | 2026-08-28 | 2026-08-28 |
| EVO-019 | Escalate to HOME when BACK can't leave a blocked page | web_blocker (native) | 2 | proposed | S | 2026-08-28 | — |
| EVO-020 | Reel identity from the settled pager page + 1 s dwell (counter) | content_counter (native) + One Reel gate | 2 | done | M | 2026-08-29 | 2026-08-29 |
| EVO-021 | Back off the stage-3 DFS on counting-pass misses | content_counter (native) | 2 | done | S | 2026-08-29 | 2026-08-29 |
| EVO-022 | Truthful counter states (bubble grant, counting off) | content_counter, appearance, dashboard | 2 | done | S | 2026-08-29 | 2026-08-29 |
| EVO-023 | Run the native JVM tests in the precommit gate | tool | 2 | done | S | 2026-08-29 | 2026-08-29 |
| EVO-024 | Per-platform pager view-id for reel identity | content_counter (native) + config schema | 2 | done (mechanism; per-app ids pending device calibration) | M | 2026-08-29 | 2026-08-29 |
