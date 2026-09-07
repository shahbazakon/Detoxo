# Block Screen (the intervention wall)

Written from shipped source. The block screen is the full-screen native window Detoxo raises at
the moment of a block — instead of the invisible BACK/HOME press plus a 1.5 s toast it used to be.
It names **what** was blocked, **why**, today's reel count, how often the app was opened today, and
the honest ways out. Plan doc: [`plan_docs/02-M1-intervention-wall.md`](../plan_docs/02-M1-intervention-wall.md)
(shipped); evolutions EVO-025 (back-button countdown), EVO-026 (the wall survives the engine's
own BACK landing elsewhere) and EVO-027 (the opens-today line from the usage layer) are folded in.

Nothing here is on the detection hot path: the wall is raised **after** a verdict, inside the
existing debounced block regions, and never inside `matches()`.

---

## 1. Contract — an enhancement, never a precondition

- The wall **accompanies** the existing navigation (BACK for reels/websites, HOME for
  whole-app blocks); it never replaces it. With no overlay grant, with the wall switched off, or
  when the window cannot be added, the trigger site falls back to the legacy toast and the user is
  still bounced. A reel block only *wants* a wall in the **Block screen** mode or when forced
  (`WallPolicy`, [03](03-detection-engine.md) §wall rule); other modes bounce with no wall and no
  toast, by design.
- `BlockScreenOverlay.show(...)` returns `false` in every fail case; the trigger site shows the
  toast only then, so the two never stack.
- A `BadTokenException` (overlay grant revoked between the check and the add) ejects to the
  launcher (`goHome`) and tears the window down.
- The wall is always dismissible from an on-screen action; it never imitates system UI; an app
  outside its stays-over set or a system dialog coming to the foreground takes it down (§4).

## 2. Window — `overlay/BlockScreenOverlay.kt`

An `object` (like `ServiceEventBus`), so the accessibility service's four trigger sites and
`CommandHandler`'s preview arm share **one** window and can never stack two. Android members
(`Handler`, `WindowManager`, the usage-query executor) are `by lazy` so the JVM test can load the
class; every public call runs on the main looper (`runOnMain`, the bubble's idiom). Both the
service callbacks and the MethodChannel run there, so no locking.

| | Value |
|---|---|
| Type | `TYPE_APPLICATION_OVERLAY` (API 26+), `TYPE_PHONE` below — shared `overlayType()` in `overlay/OverlayWindows.kt` |
| Flags | `FLAG_NOT_FOCUSABLE \| FLAG_NOT_TOUCH_MODAL \| FLAG_LAYOUT_IN_SCREEN \| FLAG_LAYOUT_NO_LIMITS` = **808** (`overlayFlags()`) |
| Size / gravity | `MATCH_PARENT` × `MATCH_PARENT`, `TOP \| START`, `TRANSLUCENT` |
| Cutout | `LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS` (API 30+), `SHORT_EDGES` (28–29); `setFitInsetsTypes(0)` on 30+ so it draws under the system bars |
| Touch | root `isClickable = true` + `setOnTouchListener { true }` — children (the real buttons) get the touch first, the backdrop swallows the rest |

`show(context, payload, staysOver, preview, raisedOver)` — cheapest check first: a standing,
attached wall for the **same** payload (the opens count aside) returns `true` and only widens its
stays-over set; a standing wall for a **newer** payload (a drained bank, a fresh count) is rebuilt
in place; a detached tracked window is torn down and re-added. Only then is the persisted style
read (`enabled == false` → `false`, unless `WallPolicy.bypassesSwitch(payload,
store.defaultBlockMode)` — a forced block or a reel wall in the Block screen mode; a `preview`
always honours the switch; the grant is never skipped), then the overlay grant: a denied check is memoised for
`OVERLAY_RECHECK_MS = 5000` so a missing grant costs one binder call per 5 s, not one per block;
the once-per-process `Log.w` names the reason. After a successful add the overlay arms the ghost
exit's countdown and kicks off the opens-today query (§5).

### Back-gesture defence — both mechanisms

1. `systemGestureExclusionRects = [Rect(0,0,w,h)]` re-applied on **every layout pass** of the wall
   (first layout, rotation, fold) through an `OnLayoutChangeListener` (API 29+) — the system clamps
   this to a maximum height, which is expected.
2. Two full-height edge **strips** (`TOP|START`, `TOP|END`), flags `NOT_FOCUSABLE | NOT_TOUCH_MODAL`
   (= 40), each swallowing touches. Width from the pure `stripWidthPx(sdkInt, gestureLeftPx,
   gestureRightPx, density)`: API 30+ → `max(left, right) × 1.5` from
   `WindowInsets.Type.systemGestures()`; below → 50 dp. A width of 0 (three-button navigation)
   adds no strips.

The defence is **touch-only** by design: an accessibility service's global BACK, a bottom-edge
gesture on some OEM shells, or a free-form window still routes around it (the `ponytail:` marker
on the object). The upgrade path is a third bottom strip behind a per-OEM flag.

### Actions

The renderer reports a token; the overlay posts `blockScreenAction` (§7) and then:

| Token | Effect |
|---|---|
| `GO_HOME` | `hide()` + `goHome()` (`ACTION_MAIN` + `CATEGORY_HOME` + `NEW_TASK` — works with no Activity and no service) |
| `OPEN_APP` | `hide()` + `launchDetoxo()` (`getLaunchIntentForPackage` + `NEW_TASK \| SINGLE_TOP`, shared with the bubble) |
| `DISMISS` | `hide()` only — "Back to Instagram" / "Dismiss" / "Got it" |
| `UNBLOCK` | **M8**: writes `ConfigStore.pendingUnblock = "TYPE\|id"`, then `hide()` + `launchDetoxo()` — the `OPEN_APP` shape. Dart drains it with `takePendingUnblock` (read-and-clear) and opens the duration sheet. A consumable prefs key rather than the event, because on a cold start the EventChannel sink does not exist when the action is posted. `preview` never writes: the style editor's sample wall must not arm a real unblock ([31](31-locked-rules-and-unblock.md) §5) |

**The ghost exit counts down (EVO-025).** The renderer tags "Back to {app}" with
`BlockScreenRenderer.TAG_BACK`; after the add the overlay disables it, dims it to 55 % and ticks
its label "Back to Instagram · 5 … · 1" once a second (`TICK_MS`) for `BlockScreenStyleSpec.
backDelaySec` seconds (default 5, `0` = instant), then restores label and state. "Go home" and
"Open Detoxo" are never delayed, so the wall cannot trap. The tick is removed in `detach()`.

**The ghost exit relabels (EVO-026).** `raisedOver` remembers the package the wall was raised
over. When the service reports the foreground moved *within* the stays-over set to another package
(`onForeground(pkg)`), "Back to Instagram" would promise a return it cannot make, so it becomes
"Dismiss" (`wall_dismiss`) — same `DISMISS` action, the wall just comes down.

## 3. Trigger sites — `accessibility/DetoxoAccessibilityService.kt`

`raiseWall(payload, staysOver, raisedOver)` = `BlockScreenOverlay.show(this, payload.sanitised(),
staysOver, raisedOver = raisedOver)`; the switch bypass is the overlay's own call (§2).
Called before the `ServiceEventBus.post` (the event carries `wall: shown`, EVO-057) and before the
existing navigation, always inside a debounced region (`BLOCK_DEBOUNCE_MS` 1200 for reels and apps,
the per-host web debounce), so `show()` is never hammered per event. Every payload carries
`packageName` (the app under the wall) for the opens-today query.

| Site | Payload | `staysOver` |
|---|---|---|
| `onDetected` (reel surface blocked) | `REEL`, `referenceId = platformId`, `displayName = platformName(pkg, platformId)` (the config's `platformName`, else the app label), `blockReason = PLAN`, `plan = activePlan`, `allowance = store.reelAllowance`, `todayCount = contentCounter.todayCount()` (**-1 when counting is off** — a stale number is never shown), `allowanceLeft` (One Reel / Unblock only), `bankMs` (Conscious only). **Gated by `WallPolicy.reelWall(store.defaultBlockMode, mode, forced)`**: raised only when the user's mode is `BLOCK_SCREEN` or the block is forced (`DAILY_LIMIT`, `SCHEDULE`, or Conscious with the bank at zero); never when the resolved mode is `NONE` — nothing navigates then, and a wall over a still-playing reel would be a trap. Wanted but not shown → `toast_blocked` with the platform name (EVO-056). | `backStaysOver(pkg)` |
| `accountConscious` drain-to-empty (the 1 Hz accountant's own BACK when the bank hits 0) | the same reel payload for the foreground reel platform with `bankMs = 0`; skipped for a protected foreground. A drained bank is forced (EVO-054), so this walls in every mode | `backStaysOver(foregroundPkg)` |
| `onAppBlocked` (whole-app HOME bounce) | `APP`, `referenceId = pkg`, `displayName = appLabel = appLabel(pkg)`, `blockReason = APP_BLOCK` | `appBlockStaysOver(pkg)` = `{pkg, resolved launcher}` — the HOME that follows lands on the launcher, so the wall stays over it until the user acts; `resolveActivity` returning the resolver (`"android"`) falls back to every HOME-capable package |
| `handleBrowser` (website) | `WEBSITE`, `referenceId`/`displayName` = host for a user-rule hit, **`""` for an adult-list hit** (EVO-018), `appLabel` = the browser's label, `blockReason = WEB_RULE \| ADULT` | `backStaysOver(browser pkg)` |

`backStaysOver(pkg)` (EVO-026) = `{pkg}` ∪ `homePkgs` ∪ `{prevForegroundPkg}` — wherever the
engine's BACK can land: the app itself, any launcher (a reel opened from a notification is its
task's root), and the app the reel was opened from (a Short from a WhatsApp link returns to
WhatsApp). `prevForegroundPkg` is tracked in the window-state block (the package in front before
the current one) and never contributes our own package, System UI or the IME.

`BlockScreenPayload.sanitised()` runs on both the native and the channel path: an `ADULT` payload
loses `displayName`, `referenceId` and `offersUnblock`; any non-`PLAN` reason drops `plan` (app and
web rules fire during a live Pause too, when the plan token would lie).

`PlatformRule.platformName` (in `engine/DetectionConfig.kt`) is parsed from the config's
`platformName` so the reel wall can say "Instagram Reels" rather than "Instagram".

## 4. Hide rules

1. **Foreground change** — in `onAccessibilityEvent`'s `TYPE_WINDOW_STATE_CHANGED` block, before the
   privacy guard, cheapest check first: `isShowing() && pkg != packageName && pkg !=
   "com.android.systemui" && pkg !in a11yPkgs && !isImePackage(pkg)` → then `staysOver(pkg)`
   decides: outside the set → `hide()`; inside it → `onForeground(pkg)` (the ghost exit relabels
   once the foreground has left the app the wall was raised over). `a11yPkgs` (the enabled
   accessibility services' packages, refreshed in `reload()`) keeps a TalkBack / Switch Access menu
   from reading as "the user left". The `isShowing()` short-circuit keeps this free while no wall
   is up.
2. **`reload()`** — after a settings push: `!masterOn || now < pausedUntil` → `hide()`. A Pause or
   protection-off lifts every block, so a standing wall goes too.
3. **Screen off** — a `BroadcastReceiver` for `ACTION_SCREEN_OFF` registered on the service in
   `onServiceConnected` (`ContextCompat.registerReceiver(..., RECEIVER_NOT_EXPORTED)`), unregistered
   inside `runCatching` from both `onUnbind` and `onDestroy` (`tearDownBlockScreen()`), which also
   hide. The `MainActivity` receiver cannot do this: it lives with the UI, which is dead exactly
   when the wall is up.
4. **User actions** (§2).

Consequences worth knowing: after a reel block the wall stays until the user picks an exit,
whether the BACK left them in the reel app ("Back to Instagram" returns to the app's other
screens), on the launcher, or in the app the reel was opened from (the ghost exit reads "Dismiss"
there). Leaving by any other route — a notification into a third app — takes the wall down. After
an app block the wall stays over the launcher until "Got it" / "Open Detoxo".

## 5. Renderer — `overlay/BlockScreenRenderer.kt`

`BlockScreenRenderer.build(context, payload, spec, onAction): View` returns a `FrameLayout`:

- **`WallView`** (Canvas, tagged `TAG_WALL`): a vertical gradient from the widget palette, a 32 dp
  glass **plan chip** (only when `plan != ""`), the headline, the reason line, and up to three stat
  lines. Text wraps with `StaticLayout` (app labels and hosts are long). The block is **measured
  before it is drawn**: it starts 34 % down the screen, but the pure `wallTextTop(height,
  blockHeight, reservedBottom, gap, minTop)` pulls it up to clear the button column — whose
  laid-out height the renderer feeds back as `reservedBottom` — at large font scales, never above
  a 48 dp cutout guard. The backdrop carries one `contentDescription` in reading order, refreshed
  when a late stat lands.
- **Buttons**: real `android.widget.Button`s in a bottom `LinearLayout` (min height 48 dp, 12 dp
  gap, `RippleDrawable` over a rounded `GradientDrawable`, `isAllCaps = false`, a
  `contentDescription` each), padded clear of the navigation bar via `setOnApplyWindowInsetsListener`.
  Reel / website: **Go home** (primary), **Open Detoxo**, **Back to {app label}** (ghost, tagged
  `TAG_BACK`). App: **Got it** (primary), **Open Detoxo**. `Allow for a while` — which, since EVO-050, expands **in place** into a
  5 / 15 / 30 / 60 chip row rather than launching Detoxo, so the decision is
  made on the wall (see [31](31-locked-rules-and-unblock.md) §5) — renders only when
  `offersUnblock`, which since M8 is true at the **non-strict** trigger sites only: an App Blocker
  lock and a non-strict package rule yes, the strict arm no, a reel block `!rule.strict`, and a
  website hit only when `match == RULE && !webEngine.matchesAdult(host)` — a host on **both** the
  user's blocklist and the 18+ set would otherwise get a button that mints a grant the adult walk
  immediately overrules. `ADULT` is already forced false by `sanitised()`
  ([31](31-locked-rules-and-unblock.md) §5). The primary fill's text colour is the pure `onColorFor(fill)`: navy on the
  teal / mint accent (≥ 6:1 both themes), **white on a deep-red usage band** where navy falls to
  3.6:1 — "Colour by usage" swaps the accent for `UsageLadder.color(todayCount)`.
- **Copy** (`WallCopy`): headline reuses `toast_blocked` ("%1$s is blocked by Detoxo") /
  `toast_blocked_adult`; reasons `wall_reason_*` — including `wall_reason_schedule_until` /
  `wall_reason_daily_limit_until`, used when the payload's `unlocksAtMs > 0` so a rule wall reads
  "Blocked by a schedule · Unlocks at 5:30 PM" instead of stopping at the reason (EVO-028; the time
  is rendered with `DateFormat.getTimeFormat(context)`, i.e. the device's 12/24-hour setting);
  stats `wall_count_today` (plurals),
  `wall_bank` (mm:ss), `wall_allowance_left` (plurals), `wall_opens_today` (plurals, "Instagram
  opened 7 times today"). All in `res/values/strings.xml` except the **plan labels**, which are
  the pure file-level `planLabel(token, allowance)` so a JVM test can pin `"CURIOUS" → "Conscious"`
  and `"ONE_REEL"` → "One Reel" (allowance 1) / "Unblock" (2+). The wire token `curious` never
  reaches a screen — asserted natively and in Dart.
- **Palette**: `WidgetBitmapRenderer.paletteFor` / `Palette` / `blend` / `withAlpha` /
  `isSystemDark` (`internal`) — the home widget's four backgrounds × two themes are the wall's.
  Body text is `today` (≥ 16:1) / `total` (≥ 5.5:1); the accent is a chip and primary-button
  fill only.
- Typeface is `Typeface.DEFAULT` / one shared bold (no bundled font natively); sizes via
  `TypedValue` sp, so the platform font scale applies.
- `ponytail:` content renders on a Canvas, so the wall cannot reuse the Flutter design system;
  the upgrade path (a Flutter-rendered wall) costs a second engine and is blocked by the
  single-process invariant.

### The late stat — "opened N times today" (EVO-027)

The first user-visible consumer of the usage layer ([26](26-catalog-and-usage-signal.md) §2). A
live wall's payload has `opensToday = -1`; after a successful add, when `spec.showOpens` and the
payload names a package and label, the overlay runs `UsageQuery.hasAccess` + `UsageQuery.opensToday
(packageName)` on its lazy single-thread executor (today's `queryEvents` window, foreground
*transitions* only) and posts the line into `WallView.extraStat`, which invalidates once and
refreshes the backdrop's description. No grant → no line, no error; a query failure is swallowed;
a wall that changed meanwhile ignores the result. The editor's preview payload carries `opensToday`
directly (`WallCopy` renders it) so "Try it" mirrors the Flutter preview.

## 6. Style and the on/off switch

Native is the single source of truth: `ConfigStore.blockScreenStyleJson` (key `block_screen_style`
in `detoxo_engine_prefs`, default `""`), parsed by `BlockScreenStyleSpec.fromJson` — `enabled`
(default **true**), `theme` (`SYSTEM | LIGHT | DARK`), `background` (`GLASS_DARK | GLASS_BRAND |
SOLID | USAGE_TINT`), `showCount`, `showOpens` (default true), `accentByUsage`, `backDelaySec`
(default **5**, clamped 0–60; 0 = instant); malformed → defaults. Read once per new wall in
`show()`, never per accessibility event and not for an already-standing wall.

Dart (`lib/features/blocking/block_screen/`):

| Layer | File | Role |
|---|---|---|
| domain | `entities/block_screen_style.dart` | `BlockScreenStyle` (Equatable; reuses `WidgetTheme` / `WidgetBackground` from the content counter's domain), `fromWire` tolerant of wrong-typed fields, `backDelaySec` clamped |
| domain | `entities/block_screen_payload.dart` | `BlockScreenPayload` (incl. `packageName`, `opensToday`), `BlockReferenceType`, `BlockReason`, `.preview()` (a zero count shows the sample 12). The native payload also carries `unlocksAtMs` (EVO-028) — native-internal, it never crosses the channel |
| domain | `entities/block_screen_copy.dart` | `BlockScreenCopy.from(payload, style)` — the Flutter mirror of `WallCopy` (MIRROR CONTRACT): the opens line, and the ghost button `locked` with its "· 5" label while the countdown runs |
| domain | `repositories/block_screen_repository.dart` | `style()`, `setStyle()`, `preview(payload)`, `hide()` |
| data | `repositories/block_screen_repository_impl.dart` | over `EngineChannel`: `blockScreenStyle` / `setBlockScreenStyle` / `showBlockScreen` / `hideBlockScreen` |
| presentation | `block_screen_style_cubit.dart` | app-wide (`main.dart`); emit now, 120 ms debounced push, dirty-guard against a late hydrate (`CounterAppearanceCubit` shape); `setShowOpens`, `setBackDelay(on:)` (5 / 0), `preview(payload)` for "Try it" |
| presentation | `block_screen_style_screen.dart` | route `Routes.blockScreenStyle` = `/block-screen/style`: live preview (the user's current plan and allowance, selected as two-field records so counter ticks don't rebuild the editor), **Try it on your phone**, Background carousel, Theme segmented, Show toggles (reel count, times opened, colour by usage), **Friction → Wait before going back** |
| presentation | `widgets/block_screen_preview.dart` | Flutter mirror of the wall; `compact` = landscape crop for the Appearance card; palette + `onColorFor` from `content_counter_appearance/.../widget_palette.dart`; a locked ghost button draws at 55 % |

The plan label itself lives with the enum — `planLabel(BlockingPlan?, {allowance})` in
`blocking/shared/domain/entities/enums.dart` — and the dashboard status label and the Unblock
dialog's base label delegate to it, so the wire token maps to "Conscious" in one Dart place.

The **Appearance** hub gains a "Block screen" section: one full-width `_SurfaceCard` with the
compact preview, the **on/off `AppToggle`**, a "Block screen off — app & website blocks fall back
to a short toast" hint (reel walls follow the block mode, not this switch), and the same
overlay-permission notice the bubble card uses
(`ContentCount.overlayGranted == false`, tri-state — never "unknown reads as denied").

"Try it" is gated on that tri-state: a definite `false` gets the permission hint; a `false` from
`showBlockScreen` (which cannot distinguish "off" from "no native side") gets a neutral message.

The `blocking.dart` barrel exports the block-screen cubit and preview (the `content_counter.dart`
precedent) so the Appearance hub reaches them without a boundary violation; the editor screen is
routed, so `app_router.dart` imports it directly.

## 7. Channel delta

Commands on `com.errorxperts.detoxo/commands` (contract detail in
[18](18-platform-channel-contracts.md)): `showBlockScreen` (payload map → `Boolean`, raised as a
**preview**), `hideBlockScreen`, `isBlockScreenShowing`, `goHome`, `setBlockScreenStyle`
(`{style: Map}`), `blockScreenStyle` (→ map, `{}` when unset). The preview arm holds the overlay
through the object, so it works with the service dead — unlike `performBack` / `killApp` /
`lockScreen`, which route through the service instance.

Event `blockScreenAction` — `{action, referenceType, referenceId, preview}`; not sticky.

## 8. Analytics

`FirebaseNativeEventReporter` logs `block_screen_action { action }` for a non-preview event, and
`block_triggered { platform, mode, wall }` — `wall` is 1 when the block screen was actually shown
for that block (EVO-057), since `mode` reports the navigation (`PRESS_BACK` for the Block screen
mode).
`referenceId` (a host or package) is never forwarded — the same rule as `webBlocked`'s host.
No Dart navigation happens on `OPEN_APP`: native foregrounds Detoxo where it was (cold start →
splash → dashboard), so the PIN and permission gates win by construction. `ponytail:` a
deep-link landing on the dashboard is M6's shell work.

## 9. Tests

- JVM (`android/app/src/test/.../overlay/BlockScreenGeometryTest.kt`, in the precommit gate):
  `overlayFlags() == 808`; `stripWidthPx` at both SDK branches; `onColorFor` / `contrastRatio`
  (navy on both accents and the green band, white on the deep-red band); `wallTextTop` (room to
  spare, pulled up, never above the guard); the `planLabel` table and the "never contains
  `curious`" sweep; `sanitised()` for adult and app-block payloads; `fromMap` null cases and the
  new field defaults; spec defaults (on, count + opens shown, 5 s). `overlay/WallPolicyTest.kt`
  pins the wall rule: Block screen mode walls and other modes do not, a forced block walls in
  every mode but never over a `NONE` navigation, forced = daily limit / schedule / Conscious bank
  at zero, and the Appearance switch is skipped by forced walls and by a reel wall in the chosen
  mode — never by an app or website wall. `engine/UsageQueryTest.kt`
  pins `startOfDay` (two zones) and `countOpens` (transitions only). Window lifecycle and `org.json`
  parsing need a device (the unit-test stub jar has no real `JSONObject`).
- Dart: `test/block_screen_test.dart` (payload/style round-trips incl. the new fields, the
  sample-12 rule, adult anonymisation, plan chip rule, `planLabel`, `BlockScreenCopy` for Conscious
  / Unblock-5 / app / adult, the locked ghost label, the opens line and its toggle, `showCount`,
  `onColorFor`, `backDelaySec` clamping), `test/block_screen_cubit_test.dart` (hydrate, debounce,
  dirty guard, `enabled=false` push, failed hydrate), `native_event_reporter_test.dart`
  (`blockScreenAction` logged, preview skipped; `block_triggered` carries `wall`),
  `test/block_mode_picker_test.dart` (the four-row picker, the selected row reaches Semantics,
  the entry tile's "Needs Display over other apps" row only without the grant),
  `test/domain_test.dart` (`BLOCK_SCREEN` round-trips).
- Device sanity (not automatable here): wall on an Instagram Reel within the debounce; both edge
  swipes swallowed, also after a rotation; "Back to Instagram · 5" ticks to 0 and unlocks while
  "Go home" stays instant, and the Friction toggle off makes it instant; a reel opened from a
  notification → BACK lands on the launcher → the wall stays and the ghost exit reads "Dismiss"; a
  Short from a WhatsApp link → the wall stays over WhatsApp; "Instagram opened N times today"
  appears within ~1 s, is absent with Usage access revoked, and the Show toggle hides it; at font
  scale 1.5× and 2× the text block clears the buttons; with "Colour by usage" on and a deep-red
  band the primary button's text is white; "Go home" ejects; "Open Detoxo" foregrounds Detoxo with
  the PIN gate intact; screen-off hides; a second block does not stack; an app-block shows "Got it"
  over the launcher; a third app foregrounding hides it; the Conscious bank draining mid-reel raises
  it; revoking "Display over other apps" mid-session falls back to toast + BACK with no crash;
  TalkBack reaches every button, reads the late opens line, and its menu does not take the wall
  down; the Appearance switch off restores the toast-only behaviour for app and website blocks;
  a reel block walls only in the **Block screen** mode — and still does with the Appearance switch
  off; a spent daily limit, a schedule and a drained Conscious bank wall in every mode with the
  switch off; Block screen mode with the overlay grant revoked toasts the platform name; toggling
  the Appearance switch while a forced wall stands keeps it up.

## 10. Play policy notes

See [22-play-release.md](22-play-release.md) §3 and §5: the wall is raised by the accessibility
service at the moment of a block, is always dismissible from an on-screen action (the countdown
delays only the ghost exit, never "Go home"), can be switched off, never imitates system UI or
covers a system dialog or an app outside the one the block came from, its launcher, or the app it
was opened from, captures no input meant for other apps, and is removed on screen-off, Pause,
protection-off and overlay revoke (falling back to the toast + BACK).

## The late-filled stat lines (EVO-027, EVO-034)

Two figures reach the wall after it is already on screen, because both need a
`UsageStatsManager` query that must not run on the main thread:

- **"Instagram opened 7 times today"** — `UsageQuery.opensToday` (EVO-027).
- **"1h 10m today in Instagram"** — `UsageQuery.timeTodayMs` (EVO-034), rendered
  only at a minute or more, since "0m today" beside a block reads as a bug.

`BlockScreenOverlay.loadOpens` runs **both** on the existing `io` executor in one
pass — behind a single `hasAccess` check, with no grant meaning no lines and no
error — then posts back once, so the wall never repaints twice. `WallView`
exposes them as `extraStats: List<String>` (it was a single `String` before
EVO-034) so each renders as its own block, exactly like `WallCopy.stats`.
`sameWall` guards the late post: if the wall moved on while the query was in
flight, the result is dropped.

Kotlin `UsageQuery.formatHm` mirrors Dart `formatHm`
(`lib/core/utils/duration_format.dart`) so the same span never reads two ways
across the process boundary; both truncate seconds rather than rounding up.
Pinned by `UsageQueryTest`.

## Source files

- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenOverlay.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/BlockScreenRenderer.kt` (payload, style spec, `planLabel`, `onColorFor`, `wallTextTop`, `WallCopy`, `WallView`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/WallPolicy.kt` (`forced`, `reelWall`, `bypassesSwitch`, `MODE_BLOCK_SCREEN`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/overlay/OverlayWindows.kt` (`overlayType`, `launchDetoxo` — shared with the bubble)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (`raiseWall`, `reelPayload`, `appLabel`, `platformName`, `appBlockStaysOver`, `backStaysOver`, `prevForegroundPkg`, `a11yPkgs`, `screenOffReceiver`, `tearDownBlockScreen`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (six arms, `jsonToMap`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/UsageQuery.kt` (`hasAccess`, `opensToday`, `startOfDay`, `countOpens`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` (`blockScreenStyleJson`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DetectionConfig.kt` (`PlatformRule.platformName`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt` (`todayCount()`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/widget/WidgetBitmapRenderer.kt` (`Palette` / `paletteFor` / `blend` / `withAlpha` / `isSystemDark`, `internal`)
- `android/app/src/main/res/values/strings.xml` (`wall_*`)
- `android/app/src/test/kotlin/com/errorxperts/detoxo/overlay/BlockScreenGeometryTest.kt`, `WallPolicyTest.kt`, `engine/UsageQueryTest.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (`BLOCK_MODES` whitelist on `pushSettings`)
- `lib/features/blocking/block_screen/**`
- `lib/features/blocking/blocking.dart`
- `lib/features/blocking/shared/domain/entities/enums.dart` (`planLabel`, `BlockingMode.blockScreen`), `engine_event.dart` (`BlockEvent.wall`)
- `lib/features/settings/presentation/widgets/block_mode_picker.dart` (`blockModes`, `BlockModeOptions`, `BlockModeTile`, `OptionTile`, `PermissionNeededRow`) and the `_BlockModeSheet` / `_BlockModeTile` wrappers in `settings_screen.dart`
- `lib/features/limits/daily_limit/presentation/daily_limit_screen.dart` (the overlay-missing banner branch)
- `lib/features/content_counter/content_counter_appearance/presentation/widgets/widget_palette.dart` (`widgetPaletteFor`, `onColorFor`)
- `lib/features/additional_feature/appearance/presentation/appearance_screen.dart` (`_BlockScreenSection`)
- `lib/core/constants/channel_constants.dart`, `lib/core/platform_channels/engine_channel.dart`
- `lib/core/services/firebase/analytics/{analytics_events,analytics_service,native_event_reporter}.dart`
- `lib/core/navigation/{routes,app_router}.dart`, `lib/core/di/injector.dart`, `lib/main.dart`
- `test/block_screen_test.dart`, `test/block_screen_cubit_test.dart`, `test/block_mode_picker_test.dart`, `test/core/services/firebase/native_event_reporter_test.dart`
