# EVO-026 — Keep the wall up when the engine's own BACK ejects to another app

- Status: done (implemented 2026-09-03 in the working tree on top of 190042a; stamp the commit hash here when it lands)
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: native `accessibility/DetoxoAccessibilityService.kt`, `overlay/BlockScreenOverlay.kt`
- Commit: 190042a (working tree carries the uncommitted M0/M1 delta this builds on)
- Date: 2026-09-03
- Effort: S

## Why
Reel and website walls stay over the blocked app only, so when the BACK the engine presses
lands somewhere else — the launcher for a reel opened from a notification, or the sharing app
for a Short opened from a link — the wall is torn down within a frame and the block is invisible
again:

`android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt:794`
```kotlin
        if (mode != "NONE") raiseWall(reelPayload(pkg, platformId), setOf(pkg))
```
`…:327-335`
```kotlin
            if (BlockScreenOverlay.isShowing() &&
                pkg != packageName &&
                pkg != "com.android.systemui" &&
                pkg !in a11yPkgs &&
                !BlockScreenOverlay.staysOver(pkg) &&
                !isImePackage(pkg)
            ) {
                BlockScreenOverlay.hide()
            }
```
`docs/code_docs/25-block-screen.md` §4 records the consequence: "leaving the app by any other
route … takes the wall down".

## Expected user impact
The wall waits for an action wherever the engine's BACK lands: the blocked app, the launcher, or
the app the reel was opened from. Once the foreground has left the blocked app, the ghost button
relabels from "Back to Instagram" to "Dismiss" so it never promises a return it cannot make.
Notifications are the most common reel entry point, so this is where the block was silently
invisible.

## Technical complexity
Native only. The service remembers the previous foreground package (excluding our own package,
System UI and the IME) and raises reel/website walls over `{pkg} ∪ homePkgs ∪ {previous}`; the
hide rule gains an `else` branch that tells the overlay the foreground moved within the stays-over
set. The overlay keeps `raisedOver` and relabels the tagged back button (EVO-025's handle). One
string `wall_dismiss` ("Dismiss"). No channel or storage change.

## Performance impact
None on the per-event path beyond one string comparison already inside the `isShowing()` guard.
The stays-over set is built once per debounced block.

## Business value
`docs/info_docs/01-product-overview.md` — "Steps in **while** you're scrolling": a block the user
never sees is the generic screen-time app's morning-after chart.

## Rejected alternative
A grace timer before hiding (keep the wall ≥ 1 s regardless of foreground): flickers over
whatever comes next, and adds a clock to a service whose plan says "no new ticker".

## Rollback
Revert the two files and the string; no persisted state.

## Implementation Plan

### Current state
- `foregroundPkg = pkg` at `DetoxoAccessibilityService.kt:321`, unconditionally.
- Trigger sites pass `setOf(pkg)` (`:762`, `:794`, `:1109`); `appBlockStaysOver` (`:934-944`)
  already widens the app-block wall to the launcher.
- `BlockScreenOverlay.show(context, payload, staysOver, preview)` stores `over`.

### Target state
- Service: `@Volatile private var prevForegroundPkg: String? = null`; in the window-state block
  `if (pkg != foregroundPkg) { prevForegroundPkg = foregroundPkg; foregroundPkg = pkg }`.
- `private fun backStaysOver(pkg: String): Set<String>` = `homePkgs + pkg` plus
  `prevForegroundPkg` unless it is `pkg`, our package, `com.android.systemui`, or an IME.
- The three reel/website sites call `raiseWall(payload, backStaysOver(pkg), raisedOver = pkg)`;
  `onAppBlocked` passes `raisedOver = pkg` too.
- Hide rule: `if (!staysOver(pkg)) hide() else onForeground(pkg)`.
- Overlay: `raisedOver: String` parameter on `show`; `fun onForeground(pkg)` relabels the back
  button to `wall_dismiss` when `pkg != raisedOver`.

### Repo conventions to follow
The existing `appBlockStaysOver` helper shape; `runOnMain` for overlay entry points.

### Steps
1. `strings.xml`: `wall_dismiss`.
2. Service: `prevForegroundPkg`, `backStaysOver`, the `raisedOver` argument at four sites, the
   hide-rule `else`.
3. Overlay: `raisedOver`, `onForeground`, relabel via `renderBack()` (EVO-025).
4. Docs: `25-block-screen.md` §3 (stays-over column), §4 (consequences), §2 (actions table).

### Boundaries
Do not change the debounce constants, the a11y/IME exemptions, or the app-block path's HOME.
If the code at the cited lines has drifted from the Commit stamp above, STOP and report.

### Validation
- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries)
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] JVM tests still green (no new pure logic; the set arithmetic is exercised on-device)
- [ ] Invariants grep clean
- [ ] Production readiness: no persisted state · no grant change · offline
- [ ] Native touched → device sanity: a reel from a notification → BACK lands on the launcher → wall stays, ghost reads "Dismiss"; a Short from a WhatsApp link → wall stays over WhatsApp; a normal in-app reel → "Back to Instagram" unchanged
- [ ] `/docs-sync` run; mapped docs updated
