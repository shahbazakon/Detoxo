# EVO-038 — Block the feed, not the person: let messages and calls through a block

- Status: done
- Tier: 2 (enhancement)
- Feature: native `engine/SuppressionDecision.kt`, `notifications/DetoxoNotificationListener.kt`
- Commit: 190042a
- Date: 2026-09-04
- Effort: M

## Why

Notification suppression shipped all-or-nothing per app: a locked Instagram's DM
notification was cancelled alongside its "3 new reels" notification. That is precisely the
blunt behaviour Detoxo positions **against** — `docs/info_docs/01-product-overview.md`
states the differentiator as *"Blocks the **reels**, not the app — you can still message,
search, and post"*, and contrasts Detoxo with tools that "block a whole app
(all-or-nothing)". The shipped ceiling reproduced the competitor behaviour on the
notification surface, and was recorded as a `ponytail:` marker rather than solved.

It is also the main reason a user would leave the feature off: nobody accepts silently
losing messages as the price of not seeing reels.

## Expected user impact

A blocked app stops advertising itself but can still reach the user as a person. Direct
strengthening of the interception loop — it removes the cost that made the intervention
too expensive to keep switched on.

## Technical complexity

Native only; no channel key, no storage key, no new permission, no UI. The listener reads
one additional field, `Notification.category`, and the decision moves into the Android-free
`SuppressionDecision.isAlwaysAllowed` so it stays JVM-testable.

**Contract change, and the reason this needed a proposal:** the listener previously read
`packageName` and `key` only, a guarantee asserted in the Play prominent disclosure, the
data-safety answer, the manifest comment and four docs. All were rewritten to name the
category read. `category` is a fixed Android constant chosen by the sending app from a
closed set — it carries no user content — which is what makes the trade affordable.

## Performance impact

One nullable field read per notification **already destined for cancellation** — the check
is deliberately last, after the block decision, so it never runs for the overwhelming
majority of notifications. Nothing on the accessibility hot path.

## Business value

The clearest market-leading item in the feature: per-category intervention on notifications
is not something the whole-app-timer category does. It converts the product's core promise —
you keep the app, you lose the bottomless part — onto the notification surface, and makes
the store-listing claim true in one more place.

## Rejected alternative

Per-**channel** filtering via `sbn.notification.channelId`, which is what the original
`ponytail:` marker named as the upgrade path. Lost on two counts: `channelId` is an
app-defined arbitrary string, so it cannot be classified without either per-app knowledge or
a UI asking the user to sort each channel by hand; and it is a strictly larger privacy read
for a worse result. `category` is semantic, standard, closed-set and needs no configuration.

## Rollback

Delete `isAlwaysAllowed` and its call site, and restore the previous disclosure/manifest/doc
wording. No persisted state, no migration. One-way door: **none**, but the Play disclosure
copy changed, so a rollback must revert that too or the disclosure over-states the read.

## Implementation Plan

### Target state
`SuppressionDecision.isAlwaysAllowed(category: String?)` returns true for
`msg`, `call`, `email`, `alarm`, `reminder`, `event` — the `Notification.CATEGORY_*`
values, mirrored as string literals rather than imported so the object stays Android-free
(the `RuleEngine.REASON_*` precedent, `RuleEngine.kt:240-246`). A **null** category is not
exempt: an app must not opt itself out of a block by omission.

Called from `onNotificationPosted` **after** `shouldSuppressNotification`.

### Verification
3 JVM tests in `SuppressionDecisionTest`: the six allowed categories pass; `social`,
`promo`, `recommendation`, `status` and empty do not; null is not exempt. Device: lock
Instagram → a reel notification is silenced, a DM arrives.
