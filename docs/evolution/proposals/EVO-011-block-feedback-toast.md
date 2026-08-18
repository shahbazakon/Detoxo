# EVO-011 — Show a "Blocked by Detoxo" toast at the block moment

- Status: done — implemented 2026-08-17; verified on-device 2026-08-18 (Realme RMX3997: "example.com blocked by Detoxo" toast captured at the block moment; commit pending)
- Tier: 2 (enhancement) — approved by user in-conversation 2026-08-17
- Feature: android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility (native only)
- Commit: c0c5251
- Date: 2026-08-17
- Effort: S

## Why
A blocked website today just bounces via `GLOBAL_ACTION_BACK`
(`DetoxoAccessibilityService.kt` `handleBrowser()`), with no attribution. Users can't
tell a Detoxo block from a browser glitch. Market blockers (BlockSite, Freedom) all
render an explicit block moment.

## Expected user impact
The intervention becomes legible: a brief toast confirms the block and names the app
doing it. Strengthens the in-the-moment intervention loop (product overview: "a firm,
friendly nudge exactly when you need it").

## Technical complexity
Native Kotlin only, one file. No channel keys, no storage, no manifest changes. Android
text toast from the (foreground) accessibility service.

## Performance impact
Fires only on an actual block — gated by the existing 1200 ms debounce + 1100 ms back
rate limit. Off the per-event hot path.

## Business value
Differentiator-adjacent (in-the-moment feedback) + store-listing story. Cites
`docs/info_docs/01-product-overview.md` "The solution".

## Rejected alternative
Full-screen overlay block page via the overlay permission — richer, but heavier
(window management from the service, dismissal UX, per-browser interplay). Toast ships
the value in one line; the overlay chip remains the upgrade path.

## Rollback
Delete the toast lines. No persisted state, no contract change.

## Implementation Plan

### Current state
`DetoxoAccessibilityService.kt` `handleBrowser()` (~line 411-420): records the block,
posts `webBlocked`, logs, then `pressBackWithRateLimit()`.

### Target state
After `pressBackWithRateLimit()`, show
`Toast.makeText(this, "$host blocked by Detoxo", Toast.LENGTH_SHORT).show()`.
`ponytail:` comment naming the ceiling (plain text toast; upgrade path = overlay chip).

### Steps
1. Import `android.widget.Toast` in `DetoxoAccessibilityService.kt`; add the toast call
   in `handleBrowser()` after the back press.

### Boundaries
Touch only `DetoxoAccessibilityService.kt`. If `handleBrowser` has drifted from commit
c0c5251, stop and report.

### Validation
- [ ] `bash tool/dev.sh precommit`
- [ ] Manual device: blocked URL in Chrome shows the toast once per block
- [ ] `/docs-sync`
