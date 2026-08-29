# EVO-040 — Give the onboarding funnel a denominator

- Status: done (in the working tree; stamp the hash on commit)
- Tier: 2 (enhancement) — changes what is emitted
- Feature: onboarding, core/services/firebase
- Date: 2026-09-04
- Effort: S

## Why
`OnboardingCubit.advance` fired `onStep`; `load()` did not. So on a fresh install
`onboarding_step{WELCOME}` never emitted and the first recorded step was whatever
the user advanced TO — welcome→survey drop-off, the most valuable number in the
funnel, had no denominator. Worse, `advance` is also the Back path, so a backward
move emitted the same event as a forward one and inflated every step total by an
unknown amount.

## Expected user impact
None directly. Indirectly: the copy and step order can be tuned against real
drop-off before launch instead of guesswork.

## Technical complexity
Low. A `StepDirection` enum (`ENTER` / `FORWARD` / `BACK`) with wire tokens,
`onStep` gains the direction, `load()` fires `ENTER` for the resumed step, and
`logOnboardingStep` gains a `direction` param.

## Performance impact
None — one extra string param on an event that already fires per step change.

## Business value
The first run is the top of every other metric; a funnel that cannot be measured
cannot be improved. Costs nothing at runtime.

## Privacy
Unchanged and re-verified: only the step token and the direction token cross the
wire. Never the name, the screen-time band or the picked feeds. Both are fixed
enum strings. `onboarding_step` is 15 chars, matching Firebase's
`[a-zA-Z][a-zA-Z0-9_]*` and the 40-char cap.

## Rejected alternative
A separate `onboarding_completed` event instead of the ENTER marker. It would
give a conversion rate but still no per-step denominator, so the interesting
question — which step loses people — stays unanswerable.

## Rollback
Drop the `direction` param and the `load()` call.

## Implementation Plan
1. `analytics_events.dart`: add `AnalyticsParam.direction`.
2. `analytics_service.dart`: `logOnboardingStep(String step, {required String direction})`.
3. `onboarding_cubit.dart`: add `StepDirection`; `onStep` becomes `(step, direction)`; `load()` fires `enter`; `advance` derives forward/back from the step index.
4. `onboarding_screen.dart`: pass both tokens through.
