# M1 — The intervention wall (block-screen overlay)

- Status: **shipped** — engineering doc [`code_docs/25-block-screen.md`](../code_docs/25-block-screen.md); on branch `sensitive_protection` (commit pending at the time of writing).
- Shipped with these deviations from the plan below (each decided against the real code, see the engineering doc): **four** trigger sites, not three — the Conscious accountant's drain-to-empty boot raises the wall too; reel/website walls add **"Back to {app}"** (`DISMISS`) and app-block walls use **"Got it"** instead of Go home, so every action token has an emitter and a reel block never silently becomes an app block; the plan chip renders only for `blockReason = PLAN` and `ONE_REEL` labels as "One Reel" / "Unblock" by the armed allowance (payload gains `allowance` and `appLabel`); the wall has its own **on/off switch** (`enabled` inside `block_screen_style`, surfaced on the Appearance card) and is skipped for block mode `NONE`; `hide()` keys on a `staysOver` set (the app it was raised over, plus the resolved launcher for app blocks) and ignores IMEs, system UI and enabled accessibility services; a new `ACTION_SCREEN_OFF` receiver lives on the service; the overlay is an `object`; `todayCount` comes from `ContentCounter` (−1 when counting is off) and `PlatformRule.platformName` was added; **6** commands (`blockScreenStyle` added for hydration); no Dart navigation on `OPEN_APP` (it would bypass the PIN route); analytics go through the Firebase `AnalyticsService`; the wall is a `FrameLayout` of a Canvas backdrop plus real `Button`s so TalkBack gets one target per action; plan labels are a pure Kotlin `planLabel()` (the only wall copy not in `strings.xml`); `docs/suggestion_docs/` does not exist in this repo, so this doc was the sole authority for the window constants.
- Source: [B7 Overlay Block Screen](../suggestion_docs/flutter-migration/B-blocking/B7-overlay-block-screen.md) (not present in this repo — the constants below were the authority) + [B1 §5](../suggestion_docs/flutter-migration/B-blocking/B1-app-blocker.md) for the payload shape
- Feature areas: native `overlay/BlockScreenOverlay.kt`, `overlay/BlockScreenRenderer.kt`; Dart `lib/features/blocking/block_screen/`
- Effort: **L** (one new native window manager + renderer + a Dart style/copy surface)
- Blocks: M7, **M8** · Blocked by: M0 (optional — the wall can name a category if the catalog exists)

## Why now

Today a block is **invisible**. The engine presses BACK or HOME, fires a vibration, and shows a
plain-text toast. The toast site says exactly what should happen next, at
[`DetoxoAccessibilityService.kt:692`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt#L692):

> `// EVO-011: make the intervention legible — attribute the bounce.`
> `// ponytail: plain text toast; upgrade path is an overlay block chip.`

This milestone cashes that upgrade path, and goes past a chip to the full wall. It is the single
biggest product change in the plan, because the product's whole claim is
[in-the-moment intervention](../info_docs/01-product-overview.md) — and right now the moment is a
1.5-second toast the user is already scrolling past.

There is a second reason it must be native and must be a real window: a back-press can be raced.
The user swipes back into the feed faster than the debounce, and the app oscillates. A wall that
holds the screen and swallows the edge gestures ends the race.

## What the user gets

At the moment of a block: a full-screen surface saying **what** was blocked, **which plan** is
enforcing it (Block All / Conscious / One Reel / Unblock), **today's reel count**, and the honest
ways out — go home, open Detoxo, or (when the payload offers it) unblock just this one target for a
short window. Under Conscious it shows the bank; under One Reel / Unblock it shows the remaining
allowance. The intervention becomes something the user can read and reason about instead of
something that just happens to them.

## Source: what is taken, what is dropped

**Taken** — the entire `fr.i.d` control flow, which B7 flags as decompiling cleanly and therefore
verified rather than inferred: window construction, the two-mechanism back-gesture defence,
idempotent show, `BadTokenException` recovery, home eject, the swallow-every-touch listener, and
**both** payload affordances (`offersUnblock` and the open-the-app button).

**Dropped, with reasons** — each of these is a decision, not an omission:

| Dropped | Why |
|---|---|
| the source app's block-screen channel namespace | Folds into the one command channel — [invariant](00-index.md#invariants--these-override-every-idea-in-the-suggestion-docs) |
| `FakeLifecycleOwner` / `SavedStateRegistryController` | B7 needs it **only** to host a `ComposeView` off-Activity. Detoxo renders on a Canvas (following `widget/WidgetBitmapRenderer.kt`), so there is no lifecycle to fake and no AndroidX plumbing to port |
| `flutter_overlay_window` (B7's recommended hybrid) | Provides neither the gesture-exclusion strips, nor `layoutInDisplayCutoutMode`, nor home eject — B7 says so itself — and costs a second `FlutterEngine`, which the single-process invariant forbids |
| the separate `iconType` field | B7 carries `referenceType` **and** `iconType` with the same three values (`app` / `website` / `category`). Detoxo keeps one field and derives the icon from it |

### Branding — B7 is written for a different app

B7 names the other app in eight places. Every one is rewritten before a line is ported:

| In B7 | In Detoxo |
|---|---|
| its vendor-prefixed block-screen MethodChannel | `com.errorxperts.detoxo/commands` |
| its **"Open \<source app\>"** button | **"Open Detoxo"** |
| a hardcoded vendor string as the log tag | `Log.w(TAG, …)` using the service's existing `TAG` |
| its vendor package paths | `com.errorxperts.detoxo` |
| `BlockScreenOverlayManager` | `BlockScreenOverlay` (Detoxo's `overlay/` naming) |
| `HubTab.MyApps` (its Open-app target) | `Routes.home` — Detoxo's dashboard |
| `fr.i` / `bn.a` / `rn.f` obfuscated names | not reproduced; behaviour only |
| the source app's name in any user-visible copy | "Detoxo" |

This is the [naming invariant](00-index.md#invariants--these-override-every-idea-in-the-suggestion-docs),
not a style preference: **Detoxo** and **errorxperts** are the only app and vendor names anywhere in
this repo.

## Algorithm & control flow

Constants are copied **verbatim**. Every number below is from the decompile; none is a guess.

```
show(payload):
    if (!Settings.canDrawOverlays(context)) { log; return }      // silent no-op, never throw
    if (mainView != null) return                                  // idempotent

    mainView = renderer.build(payload).apply {
        isClickable = true
        setOnTouchListener { _, _ -> true }                       // swallow every stray touch
    }

    params = LayoutParams(
        MATCH_PARENT, MATCH_PARENT,
        TYPE_APPLICATION_OVERLAY,          // 2038  (TYPE_PHONE below API 26)
        FLAG_NOT_FOCUSABLE      (8)
          or FLAG_NOT_TOUCH_MODAL  (32)
          or FLAG_LAYOUT_IN_SCREEN (256)
          or FLAG_LAYOUT_NO_LIMITS (512),  // = 808
        PixelFormat.TRANSLUCENT)           // -3
    params.gravity = Gravity.TOP or Gravity.START        // 8388659
    params.layoutInDisplayCutoutMode = LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS   // 3
    if (SDK >= 30) params.setFitInsetsTypes(0)           // draw under the system bars

    try { wm.addView(mainView, params) }
    catch (BadTokenException) { goHome(); hide(); return }   // permission revoked mid-show

    applyGestureDefence()

hide():
    try { wm.removeView(mainView) } catch (IllegalArgumentException) {}
    strips.forEach { try { wm.removeView(it) } catch (IllegalArgumentException) {} }
    strips.clear(); mainView = null

goHome():
    startActivity(Intent(ACTION_MAIN)
        .addCategory(CATEGORY_HOME)
        .addFlags(FLAG_ACTIVITY_NEW_TASK))              // 268435456

isShowing() = mainView != null
```

### Back-gesture defence — both mechanisms are required

Neither alone holds. The system **clamps** exclusion rects to a maximum height, so a full-screen
rect does not actually exclude the full screen; and strips alone leave the system still
interpreting the gesture in some OEM shells.

```
applyGestureDefence():
    // (a) ask the system to exclude the whole surface (it will clamp — that is expected)
    onLaidOut(mainView) {
        mainView.systemGestureExclusionRects = listOf(Rect(0, 0, w, h))
    }

    // (b) two full-height edge windows that physically swallow the touch
    stripWidth = if (SDK >= 30)
                     (max(gestureInsets.left, gestureInsets.right) * 1.5f).toInt()
                 else (density * 50).toInt()            // 50dp fallback

    for (g in [Gravity.TOP or Gravity.START,            // 8388659
               Gravity.TOP or Gravity.END]) {           // 8388661
        strip = View(context).apply { setOnTouchListener { _, _ -> true } }
        wm.addView(strip, LayoutParams(
            stripWidth, MATCH_PARENT,
            TYPE_APPLICATION_OVERLAY,                   // 2038
            FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCH_MODAL, // = 40
            PixelFormat.TRANSLUCENT).apply { gravity = g })
        strips += strip
    }

    // (c) late-layout catch: re-apply once shortly after
    mainView.postDelayed({ reapplyExclusionRects() }, 300)
```

The 300 ms re-apply replaces the original's `registerFrameCommitCallback` + `postDelayed(300)`
pair; one delayed re-apply covers the same device-robustness case with less code.

### Trigger points

The wall is raised from the paths that already decide a block, immediately **before** the existing
navigation action — the wall does not replace `pressBackWithRateLimit()`, it accompanies it, so
behaviour is unchanged if the overlay permission is missing:

| Existing site | Payload |
|---|---|
| `onDetected(...)` — reel surface blocked | `reel`, platform name, active plan, today's count |
| `onAppBlocked(pkg)` — whole-app HOME bounce | `app`, app label, `HOME` |
| the web-block branch | `website`, host for `RULE` hits; **never named** for `ADULT` hits (EVO-018 — the wall says "adult content", not the host) |

`hide()` fires on: the user tapping either action, `SCREEN_OFF`, a foreground change to a package
that is not blocked, and any `Pause` becoming active.

### Fail-safe contract

Overlay permission is **required** in Detoxo's funnel, but it can be revoked at any time.
`show()` no-ops on a missing grant and `BadTokenException` ejects to home and tears down. The wall
is therefore an *enhancement* of the existing block path, never a precondition for it — if the
window cannot be raised, the back-press still happens and the user is still protected.

## Data model

Nothing persisted except appearance, which follows the counter's existing style pattern exactly.

`BlockScreenPayload` (the wire shape, from B1 §5, trimmed to what Detoxo can populate):

```jsonc
{
  "referenceType": "REEL" | "APP" | "WEBSITE",
  "referenceId":   "com.instagram.android",   // package, host, or platformId
  "displayName":   "Instagram Reels",         // "" for adult-list hits
  "blockReason":   "PLAN" | "APP_BLOCK" | "WEB_RULE" | "ADULT" | "DAILY_LIMIT" | "SCHEDULE",
  "plan":          "BLOCK_ALL" | "CURIOUS" | "ONE_REEL" | "PAUSED",
  "todayCount":    42,
  "allowanceLeft": 0,          // One Reel / Unblock; -1 when not applicable
  "bankMs":        0,          // Conscious; -1 when not applicable
  "offersOpenApp": true,       // renders "Open Detoxo"
  "offersUnblock": false       // renders "Unblock for a while" — see M8
}
```

### The two buttons

| Button | Shown when | Emits | Handled by |
|---|---|---|---|
| **Open Detoxo** | `offersOpenApp` | `blockScreenAction {action: "OPEN_APP"}` | hide the wall, launch Detoxo with `FLAG_ACTIVITY_NEW_TASK`, land on `Routes.home` |
| **Unblock for a while** | `offersUnblock` | `blockScreenAction {action: "UNBLOCK", referenceType, referenceId}` | [M8](10-M8-locked-rules-and-app-unblock.md) — routes through M2's waiting room, then grants a per-target temporary unblock |

`offersUnblock` is B7's own field and it is the hinge for
[per-target unblocking](10-M8-locked-rules-and-app-unblock.md#part-a--per-target-temporary-unblock).
**M1 ships the button and the event; M8 ships what happens next.** Until M8 lands, the payload sets
`offersUnblock: false` everywhere and the button never renders — so M1 is shippable alone, and M8
needs no change to the wall.

Set it `false` unconditionally for `blockReason: "ADULT"`: an adult-list hit is never named
(EVO-018) and must never be one tap from being lifted.

The back gesture is a third exit and is deliberately **not** one — it is swallowed by the exclusion
rects and the edge strips. The wall always leaves at least one honest way out on screen.

> `plan` carries the wire token `CURIOUS` verbatim. The **rendered string is "Conscious"** —
> the mapping lives in `BlockScreenRenderer`, and a test asserts the string `"curious"` never
> reaches a user-visible surface.

Native persistence: one new `detoxo_engine_prefs` key `block_screen_style` (a JSON style map),
written by `setCounterStyle`'s sibling command and read at render time — the same shape and
lifecycle as the existing `cc_bubble_style` / `cc_widget_style` keys.

## Channel delta

| Method | Args | Returns |
|---|---|---|
| `showBlockScreen` | the payload map above | `true`; `false` when overlay permission is missing |
| `hideBlockScreen` | — | `true` |
| `isBlockScreenShowing` | — | `Boolean` |
| `goHome` | — | `true` |
| `setBlockScreenStyle` | `{style: Map}` — `enabled`, `theme`, `background`, `showCount`, `showOpens`, `accentByUsage`, `backDelaySec` | `true` |
| `blockScreenStyle` | — | the persisted style `Map` (`{}` when unset) — **added when M1 shipped** so the editor hydrates from native, the single source of truth |

**Six** commands, not the five this table originally listed — see the shipped-delta note at the
top of this doc, and [09](09-contracts-and-storage.md), which is the contract of record.

New event `type`: **`blockScreenAction`** —
`{action: "OPEN_APP" | "GO_HOME" | "UNBLOCK" | "DISMISS", referenceType, referenceId, preview}`.
Emitted when the user touches an action so Dart can route (open Detoxo at the right screen, or run
M8's unblock flow) and log a local analytics event. Not sticky.

The four native trigger sites call the overlay **directly in-process**; `showBlockScreen` exists on
the channel for the Dart-driven cases (previewing a style, testing the wall from settings) and
mirrors how `performBack` / `killApp` / `lockScreen` are already exposed for exactly that reason.

Full contract: [09](09-contracts-and-storage.md).

## Module layout

```
android/.../overlay/
├── ContentCounterBubble.kt          # existing — the exemplar
├── BlockScreenOverlay.kt            # NEW: window lifecycle, strips, exclusion rects, goHome
└── BlockScreenRenderer.kt           # NEW: payload + style -> View (Canvas), plan-label mapping

lib/features/blocking/block_screen/
├── domain/entities/{block_screen_payload,block_screen_style,block_screen_action}.dart
├── domain/repositories/block_screen_repository.dart
├── data/repositories/block_screen_repository_impl.dart
└── presentation/{block_screen_style_cubit.dart, block_screen_style_screen.dart}
```

Exported from the existing `lib/features/blocking/blocking.dart` barrel — this is a blocking
concern, not a new top-level feature, and adding a barrel is what
`tool/check_boundaries.sh` keys on.

## Reuse map

Everything about raising a window over other apps already exists in this repo. **Do not re-derive
it.**

| Existing | What to take |
|---|---|
| [`overlay/ContentCounterBubble.kt:84`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/ContentCounterBubble.kt#L84) | The `shown && existing != null && existing.isAttachedToWindow` steady-state fast path, and the `isAttachedToWindow` check that recovers from a revoke→re-grant cycle |
| `ContentCounterBubble.kt:94` | `Settings.canDrawOverlays` guard placed **after** the fast path, so the steady state costs no binder call |
| `ContentCounterBubble.kt:115-120` | The exact `FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCH_MODAL or FLAG_LAYOUT_NO_LIMITS` + `Gravity.TOP or Gravity.START` idiom already in use |
| `ContentCounterBubble.kt:370-373` | The `TYPE_APPLICATION_OVERLAY` / `TYPE_PHONE` SDK fallback |
| `widget/WidgetBitmapRenderer.kt` | Canvas→Bitmap rendering with background/theme/density/accent style specs — the renderer's whole approach, including `WidgetStyleSpec`'s shape |
| `engine/UsageLadder.kt` | The byte-identical Dart↔Kotlin mirror pattern, if the wall adopts the usage tint |
| `lib/features/content_counter/content_counter_appearance/` | The live-preview style editor screen, for `block_screen_style_screen.dart` |

The renderer is where the design work is; the window management is a port of a file that already
works.

## Steps

1. `BlockScreenOverlay.kt` — window lifecycle only (show/hide/isShowing/goHome + strips +
   exclusion rects), imitating `ContentCounterBubble`'s permission fast path and attach check.
2. `BlockScreenRenderer.kt` — `build(payload, style): View`, following `WidgetBitmapRenderer`.
   Owns the `CURIOUS → "Conscious"` label mapping and the adult-hit anonymisation.
3. Wire the three native trigger sites to `show(...)` **before** their existing navigation call;
   wire `hide()` to `SCREEN_OFF`, non-blocked foreground change, and pause activation.
4. Add the five command arms + the `blockScreenAction` event post.
5. Add the Dart entities, repository, and the style cubit/screen; route it from Appearance beside
   the bubble and widget editors.
6. Add the constants to `channel_constants.dart` with doc comments.
7. Tests — Dart: payload round-trip; `"curious"` never appears in any rendered string; adult
   payloads carry an empty `displayName`. Native JVM: strip width math at both SDK branches;
   `show()` twice adds one view.
8. `/docs-sync` — update 03, 04, 17, 18 and `info_docs/02` §, plus a new mapping row.

## Risks & ceilings

- `ponytail: strips are two fixed edge windows; a device with a bottom-edge back gesture or a
  free-form window still routes around them. Upgrade path = a third bottom strip behind a
  per-OEM flag.` — record at `applyGestureDefence`.
- `ponytail: content renders on a Canvas, so the wall cannot reuse the Flutter design system.
  Upgrade path = a Flutter-rendered wall, which costs a second engine and is blocked by the
  single-process invariant.` — record at `BlockScreenRenderer`.
- **Play policy.** A full-screen overlay raised by an accessibility service is scrutinised. The
  wall must be dismissible, must never imitate a system UI, and must never obstruct a system
  dialog. Update `22-play-release.md` in the same change, not after.
- **Accessibility.** The wall swallows touches by design. It must expose content descriptions on
  both actions so TalkBack users can act on it — otherwise it is a trap.

## Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] `tool/boundaries_baseline.txt` line count ≤ 8
- [ ] No new manifest permission (`SYSTEM_ALERT_WINDOW` already declared)
- [ ] Invariants grep: `"curious"` appears only in wire/code contexts; `"Conscious"` in UI strings
- [ ] Branding grep: no trace of the source app's or its vendor's name in any ported Kotlin, log
      tag, channel name or rendered string — the button reads **"Open Detoxo"**
- [ ] `offersUnblock` is `false` for every `ADULT` payload, and the button does not render
- [ ] Revoke "Display over apps" mid-session → next block falls back to the existing
      toast + back-press with no crash and no ANR
- [ ] Device sanity: wall appears on an Instagram Reel within the existing debounce; both edge
      swipes are swallowed; Go home ejects; Open Detoxo lands on the dashboard; screen-off hides
      it; a second block does not stack a second window
- [ ] TalkBack can reach and activate both actions
- [ ] Frame budget unchanged on the detection path — the wall is raised after the verdict, never
      inside `matches()`

## Target files

**New** — `android/.../overlay/BlockScreenOverlay.kt` · `android/.../overlay/BlockScreenRenderer.kt` ·
`android/app/src/test/BlockScreenGeometryTest.kt` ·
`lib/features/blocking/block_screen/**` · `test/block_screen_test.dart`

**Edited** — `android/.../accessibility/DetoxoAccessibilityService.kt` (3 trigger sites + hide
conditions) · `android/.../channels/CommandHandler.kt` · `android/.../engine/ConfigStore.kt`
(+`block_screen_style`) · `lib/core/constants/channel_constants.dart` ·
`lib/features/blocking/blocking.dart` · `lib/core/navigation/{routes,app_router}.dart` ·
`lib/features/additional_feature/appearance/presentation/appearance_screen.dart`
