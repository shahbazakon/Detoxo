# EVO-002 — Harden the PIN KDF (PBKDF2, transparent re-hash on next unlock)

- Status: proposed
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/features/access_protection (domain/pin_hasher.dart, entities/pin_config.dart)
- Commit: d0ab47e
- Date: 2026-08-08
- Effort: S

## Why

`PinHasher.hash` is a single unstretched SHA-256 round (`pin_hasher.dart:19-20`).
Adequate against casual storage inspection, weak against an offline brute-force of a
4–10 digit space (≤10¹⁰ candidates — minutes on commodity hardware if the secure-storage
blob is ever extracted). Already an acknowledged follow-up in
`docs/code_docs/08-pin-lock-recovery.md` §5 note and §12.

## Expected user impact

Invisible. Protection only matters if device storage is dumped — defense in depth for
the app's highest-trust surface.

## Technical complexity

Dart-only. `PinConfig` gains a `kdfIterations` field (0 = legacy single round —
storage-schema addition, migration-free via `fromJson` default). On a successful
`verify()` against a legacy hash, re-hash with PBKDF2-HMAC-SHA256 (package `crypto`
suffices via manual iteration; no new dependency) and persist — transparent migration,
no forced re-entry.

## Performance impact

~50–100 ms once per verify/setup, off the accessibility hot path (runs on the lock
screen only). Imperceptible next to the human typing a PIN.

## Business value

Backs the store-listing "Make it stick" security claim (`docs/info_docs/01` §PIN lock &
staying-honest protection); table stakes for a security feature.

## Rejected alternative

Argon2 via a native FFI package — better KDF, but a new dependency (pubspec is
deliberately lean) and native surface for marginal gain at PIN entropy levels.

## Rollback

Revert; legacy hashes still verify (iterations field defaults to 0 = old scheme).
One-way door only for configs already re-hashed — keep the legacy verify branch for
one release cycle.

## Implementation Plan

<!-- Fill this section ONLY once Status: approved. -->
