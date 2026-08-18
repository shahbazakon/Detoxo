# EVO-003 — Commitment delay on disabling the PIN lock

- Status: proposed
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: lib/features/access_protection (+ settings `_PinTile` turn-off path)
- Commit: d0ab47e
- Date: 2026-08-08
- Effort: M

## Why

Today a weak moment defeats the lock in three taps: PIN → "Turn off" → confirm
(`settings_screen.dart` `_toggle` / `pin_setup_screen.dart` `_turnOff`). The product's
own comparison table says the PIN exists to "keep future-you honest"
(`docs/info_docs/01` §Why Detoxo is different) — but present-you can dissolve it
instantly.

## Expected user impact

An opt-in "commitment mode": turning the PIN off takes effect after a chosen delay
(1 h / 24 h), with a visible pending state and the option to cancel the pending
disable. The strongest possible alignment with the differentiator; competing blockers
ship this and it is the most-requested class of feature in this category.

## Technical complexity

Dart-only. `PinConfig` gains `disableAfter: DateTime?` + a `commitmentDelay` setting;
gates treat a config with a pending-but-unexpired disable as still active. No channel,
manifest, or native changes.

## Performance impact

None — evaluated only at gate checks (screen taps), argued not asserted: no timers, the
expiry is compared lazily on read.

## Business value

Directly strengthens the differentiator row ("Optional PIN lock and uninstall
protection keep future-you honest") and retention: a lock that survives weak moments
keeps the app doing its job.

## Rejected alternative

A hard "no disable while a daily-limit streak is active" rule — clever but paternalistic
and support-ticket-prone; a time delay is predictable and always escapable by waiting.

## Rollback

Revert cleanly; `disableAfter` is an additive JSON key older builds ignore. No one-way
doors.

## Implementation Plan

<!-- Fill this section ONLY once Status: approved. -->
