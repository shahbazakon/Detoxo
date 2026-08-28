# Plans, Pause & Conscious

How Detoxo decides *whether* to block. The detection engine ([03-detection-engine.md](03-detection-engine.md)) answers "is this a reel?"; this layer answers "and should I act on it right now?" — via four **blocking plans**, a clock-based **Pause** window, the **Conscious** earn-as-you-abstain time bank, and the **One Reel / Unblock** allow-N-reels counter (the last two enforced natively).

Everything here lives under `lib/features/blocking/plans/**` (Dart) plus the Conscious accountant and the One Reel / Unblock gate inside `accessibility/DetoxoAccessibilityService.kt` (native). Plan state itself is owned by the sibling `blocking/shared` feature (`AppSettings` + `SettingsCubit`), which this doc also covers because the plan state machine is where Pause/Conscious/One Reel are driven.

---

## 1. The four plans

`BlockingPlan` (`lib/features/blocking/shared/domain/entities/enums.dart`) is the user's active high-level strategy. Each value carries a verbatim **wire token** used in persisted JSON and on the platform channel.

| Enum value | Wire token | User-facing label | Enforcement |
|---|---|---|---|
| `blockAll` | `BLOCK_ALL` | Block All | Every detected reel is acted on immediately (default). |
| `curious` | `CURIOUS` | **Conscious** | Native earn-as-you-abstain token bucket (see §5). |
| `oneReel` | `ONE_REEL` | One Reel / Unblock | Natively enforced: allow N reels (`reelAllowance` 1..20), then re-block and **auto-revert to the base mode**. One enum value, two user modes (see §7). |
| `paused` | `PAUSED` | Paused | Legacy/derived only — see §3. Never the persisted `activePlan` in the current model. |

### Base vs override modes (read this)

The plans split into two kinds by **lifetime**:

- **Base modes (sticky):** **Block All** (default) and **Conscious**. Choosing one records it in the persisted `AppSettings.baseMode` (a `BlockingPlan`, wire key `baseMode`, only ever `blockAll` / `curious` — `AppSettings.fromJson` collapses anything else, incl. an override plan or legacy `paused`, to `blockAll`). This is the mode the app **returns to**.
- **Override modes (temporary):** **One Reel**, **Unblock**, and **Pause**. Each grants a bounded allowance — a reel count or a time window — and when that unit completes the app **auto-reverts to the base mode** instead of sitting put. So an override run from a **Conscious** base returns to **Conscious**, not Block All. (`baseMode` is threaded through `AppSettings`' ctor / `fromJson` / `copyWith` / `toJson` / `props`.)

### The `curious` / `CURIOUS` ↔ "Conscious" mapping (read this)

The **internal token is `curious` / `CURIOUS` and must stay verbatim** everywhere in code and on the wire. The **user-facing name is "Conscious."** This is a deliberate, verified split — do not rename the token to match the label.

The mapping is applied in three concrete places:

- **Dart plan enum:** `BlockingPlan.curious('CURIOUS')` — the constant and its wire string.
- **UI relabel:** the dashboard status maps `BlockingPlan.curious → 'CONSCIOUS'` (`dashboard_tab.dart` `_statusLabel`), and the session dialog / hero all read "Conscious." The turn-on/turn-off actions are `SettingsCubit.enterConscious()` / `stopConscious()`, which set/clear `BlockingPlan.curious`.
- **Native:** the accountant's active-plan token is `private const val PLAN_CONSCIOUS = "CURIOUS"` — i.e. the class is *named* "Conscious" but it matches on the `"CURIOUS"` wire string that Dart pushes.

So: **`curious`/`CURIOUS` (code/wire) = "Conscious" (everything the user sees).**

---

## 2. Plan state machine — `SettingsCubit`

`lib/features/blocking/shared/presentation/settings_cubit.dart` owns the single `AppSettings` object and is the only writer. Every mutation runs through one `_commit(next)` path that **persists locally → pushes the derived state to native → re-syncs the pause ticker**:

```dart
Future<void> _commit(AppSettings next) async {
  emit(next);
  await _settings.save(next);        // local_store
  await _engine.pushSettings(next);  // MethodChannel pushSettings
  _syncTicker(next);
}
```

Plan-relevant actions:

| Method | Effect |
|---|---|
| `setPlan(plan)` | Switch active plan; **clears any live pause** (`clearPauseSession: true`) — the user is choosing fresh. When the plan is a **base** (Block All / Conscious) it also records it as `baseMode` (`baseMode: isBase ? plan : null`). |
| `enterConscious()` | `setPlan(BlockingPlan.curious)`, then **`await`s `_engine.resetConsciousBank()`** — a genuine user entry starts an empty bank; an auto-revert into Conscious keeps it (see §5.4). |
| `stopConscious()` | `setPlan(BlockingPlan.blockAll)` — Conscious always falls back to Block All. |
| `setOneReel({count})` | Enter One Reel (`count == 1`) / Unblock (`count` 2..20). Commits `activePlan = oneReel`, `reelAllowance = count.clamp(1,20)`, clears any pause, then fires the imperative `armReelSession(count)`. Re-arms a fresh allowance on **every** call (see §7). |
| `startPause({pause})` | Opens a pause window (see §3). Sets `activePlan = state.baseMode` up front + attaches a `PauseSession(planToResume: state.baseMode)`. |
| `resumeNow()` | Ends a live pause immediately → back to `state.baseMode` + clears the session. |

**Override auto-revert.** The temporary override modes settle back to `state.baseMode` when their unit completes: **Pause** via the 1 Hz `_onTick` (and `resumeNow`); **One Reel / Unblock** via a `reelSessionStream()` subscription set up in the ctor — `_onReelSession` flips `activePlan → baseMode` when a push arrives with `rs.active && rs.blocked` while `activePlan == oneReel` (idempotent via that guard; `_reelSub` is cancelled in `close()`). See §7.4.

`AppSettings.activePlan` never holds `paused`. `AppSettings.fromJson` includes a **legacy migration**: any persisted `activePlan == PAUSED` is collapsed to `blockAll` on load, so an upgrade killed mid-pause can't surface a phantom permanent "Paused" plan with no live window to clear it.

---

## 3. Pause — a clock-based allow-window

Pause is **not** a plan the engine enforces; it's a temporary *suspension* of blocking modelled as a live `PauseSession` carved out of whatever plan is active.

### The `PauseSession` model

`lib/features/blocking/plans/domain/entities/sessions.dart` — a three-phase contract with verified phase math `active → cooldown → idle`:

```
startedAt ──pauseDuration──▶ pauseEnd ──cooldownDuration──▶ cooldownEnd
   │            active            │           cooldown          │   idle
```

- `phaseAt(now)` → `SessionPhase.active | cooldown | idle`.
- `remainingIn(now)` → time left in the current phase (clamped ≥ 0).
- `cooldownProgressPct(now)` → 0..100 through the cooldown window; drives the cooldown emoji band (`EMOJI_PAUSE_COUNTDOWN_COOLDOWN`).
- Serializable (`toJson`/`fromJson`) — it is a field of `AppSettings` and persists across restarts.

### Current live behaviour: no cooldown wind-down

`SettingsCubit.startPause` constructs the session with **`cooldownDuration: Duration.zero`** and `planToResume: state.baseMode` (the sticky base — Block All *or* Conscious). So today a Pause is: *reel and website blocking suspended for the chosen window (whole-app locks stay enforced — [06] §2), then blocking returns immediately as the base mode* — the cooldown phase and its emoji band are **modelled but not exercised** by the current picker. The cooldown machinery (`cooldownProgressPct`, `EMOJI_PAUSE_COUNTDOWN_COOLDOWN`, `allowInCooldown`) is retained for a future graduated wind-down and should be treated as **planned / follow-up**, not live.

### How Pause reaches the engine (derived enforcement)

Native has no "pause plan" concept — Dart derives two values from the live session and pushes them over the ordinary `pushSettings` call (`AppSettings.effectiveNativePlan` / `nativePauseUntil`, wired in `engine_repository_impl.dart`):

| Pushed field | Value while pause is live | After the window |
|---|---|---|
| `activePlan` | `planToResume.wire` (the base mode: `BLOCK_ALL` or `CURIOUS`) | the real `activePlan` |
| `pauseUntil` | `pauseEnd.millisecondsSinceEpoch` | `0` |

Native gate (`DetoxoAccessibilityService.onAccessibilityEvent`):

```kotlin
// A live Pause window suspends reel/web blocking until pauseUntil. Whole-app
// locks are checked ABOVE this gate — a Pause taken for reels never unlocks a
// fully-locked app ([06] §2).
if (System.currentTimeMillis() < pausedUntil) return  // cached mirror of store.pauseUntil
```

This gate is **purely clock-based**, so it holds even if the Flutter UI is dead. Pickers/defaults come from `SessionDefaults` (`lib/features/blocking/plans/domain/entities/session_defaults.dart`): slider 2–10 min in 2-min steps (`snapPauseMinutes`), default 4, `maxPauseMinutes` 10.

### Pause ticker (UI truth)

While a pause is live, `SettingsCubit` runs a 1 Hz `_ticker` whose only job is to settle UI state back to the **base mode** (`state.baseMode` — `activePlan` is already the base) and drop the session the instant `pauseEnd` passes — native already enforces this via `pauseUntil`; the ticker just keeps the banner/state honest when the app is awake.

---

## 4. Conscious — earn-as-you-abstain, at a glance

Conscious lets reels play **only while the user has banked allowance by staying off them**. It is a **token bucket**:

- **Abstaining** (off any reel-bearing app): the bank fills at `1 / earnDivisor` of elapsed time → **+1 min per 10 min** (default). Capped at **10 min**.
- **Watching** (a reel is on screen): the bank drains **1:1**.
- **Empty bank**: the reel is booted (back-press) and blocking resumes until the user earns more.

The running balance lives **natively** so it survives the Flutter UI being killed; Dart only mirrors it for display. There is **no Dart-side Conscious session** — unlike Pause, `AppSettings` holds nothing live for Conscious.

Tuning constants (`SessionDefaults`, mirrored natively):

| Constant | Value | Meaning |
|---|---|---|
| `consciousEarnDivisor` | `10` | Earn rate: `elapsed / 10` while abstaining ("1 min every 10 min"). |
| `consciousMaxBank` | `10 min` (600 000 ms) | Bank cap. |
| `consciousEarnLabel` | "1 min every 10 min" | Human-readable earn rate string. |

---

## 5. Conscious — native accountant

Enforcement lives in `accessibility/DetoxoAccessibilityService.kt`. Bank state persists in `engine/ConfigStore.kt` (SharedPreferences file `detoxo_engine_prefs`).

### 5.1 The 1 Hz accountant

A `Handler` on the main looper posts `consciousTick` every `CONSCIOUS_TICK_MS = 1000L`. It runs **only while the active plan is Conscious**:

```kotlin
private fun syncConscious() {
  val conscious = activePlan == PLAN_CONSCIOUS  // "CURIOUS" (cached mirror)
  when {
    conscious && !consciousRunning -> { // start
      consciousRunning = true
      consciousAnchorMs = System.currentTimeMillis() // runtime-only; don't credit downtime
      lastReelAtMs = 0L
      consciousHandler.postDelayed(consciousTick, CONSCIOUS_TICK_MS)
      emitConsciousState()
    }
    !conscious && consciousRunning -> { /* stop + removeCallbacks + force-flush the bank */ }
    conscious -> emitConsciousState() // already running; just refresh UI
  }
}
```

`syncConscious()` is called from `reload()` (i.e. after every `pushSettings`), so entering/leaving Conscious starts/stops the accountant. On start it **re-anchors to now** so accumulated service downtime is never retroactively credited (the persisted bank carries over; only the elapsed clock restarts).

### 5.2 One accounting step

`accountConscious()` runs each tick. It first applies the **daily fresh start**: when `ConfigStore.consciousDate` differs from today's day key, it stamps the new day and zeroes the bank — the allowance is re-earned each day, so an overnight abstain can't stockpile a free 10-minute morning balance. It then computes `elapsed = now − consciousAnchorMs`, advances the anchor first (even if it then freezes), and classifies the current moment:

- **`watching`** = a reel was detected within `WATCH_STALE_MS = 2500L` (`now − lastReelAtMs < 2500`).
- **`inReelApp`** = the foreground package has reel surfaces but detection has gone quiet (paused video / non-feed overlay).
- Otherwise → **abstaining** (genuinely off reels).

Then:

```kotlin
if (!store.masterEnabled) { emitConsciousState(); return }  // freeze: no drain, no accrue

if (watching) {
  bank -= elapsed.coerceAtMost(CONSCIOUS_MAX_STEP_MS)   // drain 1:1, capped step
  if (bank <= 0L) { bank = 0L; lastReelAtMs = 0L; pressBackWithRateLimit() } // boot the reel
} else if (!inReelApp) {
  bank = (bank + elapsed / store.consciousEarnDivisor)   // accrue while abstaining
           .coerceAtMost(store.consciousMaxBankMs)        // capped at 10 min
}
// else: lingering on a reel app with no fresh detection → hold steady (no drain, no accrue)
```

Key rules:
- **Daily reset:** the first tick on a new day key (`conscious_date`) empties any carried bank — abstinence banked yesterday doesn't buy watch-time today.
- **Drain-step cap** `CONSCIOUS_MAX_STEP_MS = 5000L`: a delayed/coalesced tick can drain at most 5 s at once, so a stalled handler can't dump the whole bank instantly.
- **Paused-reel guard:** a reel that's on screen but not actively producing detections (`inReelApp && !watching`) neither refills the bank nor drains for free — it holds steady. Only genuine abstinence accrues.
- **Master-off freeze:** with `masterEnabled == false` the bank neither drains nor accrues; the anchor is still advanced so re-enabling can't dump a huge credit.

### 5.3 Detection-path interaction

The Conscious decision is made inside the block loop of `onAccessibilityEvent`, right after a detector matches:

```kotlin
if (activePlan == PLAN_CONSCIOUS && consciousBank > 0L) {   // cached mirrors — no prefs read
  lastReelAtMs = now   // mark "watching" so the accountant drains the bank
  return               // let the reel play
}
onDetected(pkg, platform.platformId, detector)  // bank empty → fall through to block
```

So while the bank has allowance, a matched reel simply refreshes `lastReelAtMs` and is **let through**; the accountant drains it. When the bank is empty the code doesn't touch `lastReelAtMs` and **falls through to the normal block** — a bounced reel therefore counts as abstaining, and the bank starts refilling. Note the accountant's own `pressBackWithRateLimit()` on drain-to-empty is a second boot path for the case where the bank empties *between* detection events.

### 5.4 Bank reset — genuine entry only (keeps the bank across an override)

A **genuine user entry** into Conscious starts a **fresh empty bank**; an **auto-revert back into** Conscious — after a One Reel / Unblock / Pause override that ran from a Conscious base — **keeps** the earned bank. So the reset is deliberately decoupled from the plan push:

- `pushSettings` (`channels/CommandHandler.kt`) now stores the plan **verbatim** — the old auto-reset on a `*→CURIOUS` transition was **removed**, so an auto-revert into Conscious does not wipe the bank.
- A separate **`resetConsciousBank`** command does the fresh-start reset: `store.resetConsciousBank()` (no-arg, zeroes only the bank — the anchor is a runtime-only service field now), then the service hook `onConsciousBankReset()` drops the cached bank + pending unflushed accrual and `reload()`s. It is fired **only** by `SettingsCubit.enterConscious()`, which `await`s `_engine.resetConsciousBank()` right after `setPlan(BlockingPlan.curious)`.

So tapping Conscious in the UI empties the bank, but the round-trip *override → base = Conscious* leaves it intact. `pushSettings` still ships the tuning constants each time (`consciousEarnDivisor`, `consciousMaxBankMs` from `SessionDefaults`); `ConfigStore` defaults them defensively (`divisor` ≥ 1 default 10, `maxBank` default 600 000 ms) so a missing push never divides by zero or uncaps the bank. See the command contract in [18-platform-channel-contracts.md](18-platform-channel-contracts.md).

### 5.5 `consciousState` event + Dart mirror

Every tick (and on start/refresh) native posts a `consciousState` event via `ServiceEventBus`; the same snapshot answers the `consciousState` pull query. Payload (`consciousSnapshot`):

| Field | Meaning |
|---|---|
| `bankMs` | Current banked allowance (ms). |
| `maxBankMs` | Bank cap (ms). |
| `watching` | `active && a reel is on screen now`. |
| `blocked` | `active && bank <= 0` (reels blocked, must earn). |
| `active` | The Conscious plan is the active plan. |

Dart side:
- **Entity** `ConsciousState` (`plans/domain/entities/conscious_state.dart`) — `fromMap`, plus derived `banked`/`maxBank` `Duration`s, `progress` (0..1 bank fill for the ring), `hasAllowance`.
- **Cubit** `ConsciousCubit` (`plans/presentation/conscious_cubit.dart`) — subscribes to `consciousStream()` and relays each push; calls `refresh()` once at startup (`consciousCurrent()` pull) so the display is correct before the first push. **Enforcement never depends on this mirror** — the native accountant owns the bank, so a momentarily stale read self-corrects within ~1 s.

---

## 6. Native Conscious constants (companion object)

| Constant | Value | Role |
|---|---|---|
| `PLAN_CONSCIOUS` | `"CURIOUS"` | Active-plan token Conscious matches on (the verbatim wire string). |
| `CONSCIOUS_TICK_MS` | `1000L` | Accountant cadence (1 Hz). |
| `WATCH_STALE_MS` | `2500L` | A reel detected within this window still counts as "watching." |
| `CONSCIOUS_MAX_STEP_MS` | `5000L` | Max drain per tick (guards against a delayed tick emptying the bank). |
| `BACK_RATE_LIMIT_MS` | `1100L` | Min gap between back presses (shared with the block path). |

`ConfigStore` bank keys (file `detoxo_engine_prefs`): `conscious_bank_ms` (the durable copy — the live value is cached and write-batched in the service, at most ~5 s behind), `conscious_earn_divisor`, `conscious_max_bank_ms`. The tick anchor is runtime-only in the service; its old `conscious_anchor_ms` key was deleted.

---

## 7. One Reel & Unblock — allow N reels, then block

`oneReel` (wire `ONE_REEL`) is the **other natively-enforced plan**. A single enum
value models **two user modes** through `AppSettings.reelAllowance` (int, 1..20,
default 1):

| Mode | Plan + allowance | Behaviour |
|---|---|---|
| **One Reel** | `oneReel` + `reelAllowance == 1` | Play exactly one reel, then re-block and auto-revert to the base mode. |
| **Unblock N** | `oneReel` + `reelAllowance` 2..20 | Play up to N reels, then re-block and auto-revert to the base mode. |

`reelAllowance` is the only new `AppSettings` field (wired through `fromJson`
`(json['reelAllowance'] as num?)?.toInt() ?? 1`, `copyWith`, `toJson`, `props`). Like
Conscious, the running **consumed-count lives natively** so enforcement survives the
Flutter UI being killed; Dart holds only the target allowance, not a live session.

> Historical note: `oneReel` previously existed as a stub that behaved exactly like
> Block All (no real enforcement). It is now enforced end-to-end.

### 7.1 Arming — `SettingsCubit.setOneReel`

```dart
Future<void> setOneReel({required int count}) async {
  final n = count.clamp(1, 20);
  await _commit(state.copyWith(
    activePlan: BlockingPlan.oneReel, reelAllowance: n, clearPauseSession: true,
  ));
  await _engine.armReelSession(n);           // imperative re-arm
}
```

Every mode tap **re-arms a fresh allowance**: `armReelSession` resets the native
consumed-count to zero. The re-arm is a **separate imperative command**, not just a
`pushSettings` field — so an *unrelated* settings push (toggling vibration, changing
a platform) can never refill the session mid-watch; only an explicit mode tap does.
After the Nth reel the native gate blocks and the app **auto-reverts to the base
mode** (§7.4) — it no longer sits blocked waiting for a re-tap.

**How the UI arms.** **One Reel** arms directly at count 1 (no picker). **Unblock**
opens `SessionDialogs.showUnblock` — a circular **2–20** count slider mirroring the
Pause dialog (`_PauseDialog`) — which calls `setOneReel(count:)` on confirm. Its
bounds live in `SessionDefaults`: `unblockSliderMin` 2 / `unblockSliderMax` 20 /
`unblockSliderStep` 1, `unblockDefault` 5, and `snapUnblockCount(value)` (round +
clamp to 2..20).

### 7.2 Native gate — a reel counts after 2s of dwell

Enforcement lives in `accessibility/DetoxoAccessibilityService.kt`, in the same
detector loop as Conscious. When a reel surface matches under `oneReel`:

```kotlin
if (store.activePlan == PLAN_ONE_REEL && allowReelOrBlock(now)) return  // allow it
onDetected(...)  // allowance spent → fall through and block
```

**A reel counts toward the allowance only after it's been watched for `MIN_VIEW_MS =
2s`** (matching the awareness counter's dwell). So a quick flick-through (<2s) doesn't
count, and a **single looping reel costs at most one count** — a `reelViewCounted`
latch stops the same view being re-counted. Reels are still **scroll-delimited**
(consecutive reels share one continuously-visible view-id, so `matches()` fires the
whole time a reel is up), but a scroll only counts as an **advance to a new reel**
once **≥ 2s have passed since the last count** (`lastReelCountMs`) — this debounces
in-reel scrolls (comments / caption / carousel) so they don't burn the allowance or
block the reel you're still watching. The advance scroll (`TYPE_VIEW_SCROLLED`) is
still captured into `lastScrollAtMs` **before** the 150 ms per-package throttle.

The **currently-playing reel is never blocked**; only a *fresh* reel detected after
`reelsConsumed >= reelAllowance` is blocked (`emitReelSessionState(blocked = true)`,
which drives the Dart auto-revert). Counting happens on the 2s same-reel dwell tick or
when advancing away from a reel watched ≥ 2s (covers passively-watched reels that stop
emitting events). See [03-detection-engine.md](03-detection-engine.md) §5.3 for the
full `allowReelOrBlock` / `countReel` walk.

- `reelsConsumed` is incremented **only in `countReel`** (a real 2s watch), so it caps
  at `reelAllowance` and never inflates while blocked (keeping the "N of M" gauge
  honest).
- `reelsConsumed` is **persisted** (`ConfigStore` key `reels_consumed`) so an
  OS-driven service restart keeps the user blocked until an explicit re-tap;
  `reload()` / `onServiceConnected` do **not** reset it — only `resetReelSession()`
  (called from the imperative arm) does.
- `armReelSession()` (native) zeroes the runtime dwell fields (`reelViewStartMs`,
  `reelViewCounted`, `lastReelCountMs`, `lastScrollAtMs`), calls `reload()`, and emits
  fresh state.

> **`ponytail:` ceiling** (a comment in the service): reel identity is heuristic
> (scroll + 2s dwell, no per-reel id) — a spurious scroll >2s after a count can still
> be misread as an advance, and a fast scroll within 2s of a count is absorbed into
> the current reel (a small leniency, safer than false-blocking). Accepted; the
> upgrade path is content-based reel identity.

### 7.3 Reel-session state stream + Dart mirror

Native posts a `reelSessionState` event on every allow/block and on arm; the same
snapshot answers the `reelSessionState` pull query. Payload (`reelSessionSnapshot`):

| Field | Meaning |
|---|---|
| `consumed` | Reels consumed so far this session. |
| `allowance` | Reels allowed before re-block (1..20). |
| `blocked` | `active && consumed >= allowance` (allowance spent). |
| `active` | `oneReel` is the active plan. |

Dart side:
- **Entity** `ReelSessionState` (`plans/domain/entities/reel_session_state.dart`) —
  `fromMap`, plus derived `remaining = (allowance - consumed).clamp(0, allowance)` and
  `progress` (0..1 for a gauge).
- **Cubit** `ReelSessionCubit` (`plans/presentation/reel_session_cubit.dart`) mirrors
  `ConsciousCubit`: it subscribes to `reelSessionStream()`, relays each push, and
  pulls one snapshot at startup (`reelSessionCurrent()`) so the display is correct
  before the first push. Provided app-wide in `main.dart`. **Enforcement never
  depends on this mirror** — the native engine owns the consumed-count.

### 7.4 Auto-revert to the base mode

One Reel / Unblock is an **override**: once the allowance is spent it returns to the
base mode instead of sitting blocked. `SettingsCubit` subscribes to
`_engine.reelSessionStream()` in its **constructor**; `_onReelSession` flips
`activePlan → state.baseMode` (clearing any pause) the moment a push arrives with
`rs.active && rs.blocked` while `activePlan == oneReel`:

```dart
void _onReelSession(ReelSessionState rs) {
  if (state.activePlan == BlockingPlan.oneReel && rs.active && rs.blocked) {
    unawaited(_commit(state.copyWith(
      activePlan: state.baseMode, clearPauseSession: true)));
  }
}
```

The `activePlan == oneReel` guard makes it **idempotent** — a second `blocked` event
after the flip is ignored, and arming (which emits `blocked == false`) never trips
it. `_reelSub` is cancelled in `close()`. Native still owns the count and still boots
the over-allowance reel (§7.2); Dart's job here is only to flip the plan back, so the
*next* reel is governed by the base mode (e.g. back to Conscious's bank, or straight
Block All). The `reelSessionState` event's `blocked=true` is the sole trigger — see
[03-detection-engine.md](03-detection-engine.md) §5.3.

---

## 8. The emoji-band / mindful-quote content engine

Detoxo ships a small **offline dynamic-content engine** that supplies rotating emojis (with animations) and motivational quotes for the mindful-countdown surfaces. It's the offline tier of a `ContentRepository` interface; a remote `fetchcontent` tier could layer behind the same interface later (planned / swap-in).

### 8.1 Placement model

`plans/domain/entities/emoji_band.dart`. Bundled JSON and any future remote response share one schema: a top-level `emojiSets[]`; each set has `setId`, `placementId`, `enabled`, and an `emojis[]` array of **inclusive range-bucketed** items (`rangeMin <= value <= rangeMax`, via `EmojiItem.covers`). Each item carries `emoji`, `title`, `description`, and an `animation` token.

`EmojiPlacementId` (the join key — its `wire` matches the `placementId` in the asset):

| Placement id | Wire | Bundled asset | Bucket value (domain meaning) |
|---|---|---|---|
| `planPause` | `EMOJI_PLAN_PAUSE` | `pause_emojis.json` | re-open count |
| `curiousPlan` | `EMOJI_CURIOUS_PLAN` | `curious_emojis.json` | re-open count |
| `dailyLimitHero` | `DAILY_LIMIT_HERO` | `daily_limit_emoji_bands.json` | selected daily-limit minutes |
| `pauseCountdown` | `EMOJI_PLAN_PAUSE_COUNTDOWN` | `pause_countdown_pause_emojis.json` | minutes of the pause window |
| `pauseCountdownCooldown` | `EMOJI_PAUSE_COUNTDOWN_COOLDOWN` | `pause_countdown_cooldown_emojis.json` | cooldown progress **%** (0..100) |
| `appLockSession` | `EMOJI_APP_LOCK_SESSION` | *(none — returns empty/disabled)* | — |

Asset shapes (verified counts / ranges):

| Asset | Placement | Items | Range span |
|---|---|---|---|
| `curious_emojis.json` | `EMOJI_CURIOUS_PLAN` | 11 | 0..60 |
| `pause_emojis.json` | `EMOJI_PLAN_PAUSE` | 10 | 0..30 |
| `pause_countdown_pause_emojis.json` | `EMOJI_PLAN_PAUSE_COUNTDOWN` | 11 | 0..60 |
| `pause_countdown_cooldown_emojis.json` | `EMOJI_PAUSE_COUNTDOWN_COOLDOWN` | 3 | 0..100 (percent) |
| `daily_limit_emoji_bands.json` | `DAILY_LIMIT_HERO` | 5 | 0..999999 |

Example item (`curious_emojis.json`, first band):

```json
{ "emojiId": "curious_2_0", "rangeMin": 0, "rangeMax": 5, "emoji": "🎯",
  "title": "Stay Sharp", "description": "You opened this for a reason. Don't forget it.",
  "animation": "BREATHING" }
```

### 8.2 `ContentRepository`

Interface `plans/domain/repositories/content_repository.dart`; impl `plans/data/repositories/content_repository_impl.dart` (DI singleton in `core/di/injector.dart`). It reads bundled assets **lazily + memoized**, and **degrades safely** — any parse/IO failure returns an empty *disabled* placement (`isUsable == false`) or a single fallback quote, so the countdown UI never crashes.

- `emojiPlacement(id)` → the `EmojiPlacement` (empty-disabled where no asset, e.g. `appLockSession`).
- `emojiFor(id, threshold)` → items whose inclusive range covers `threshold` (mirrors the verified `emojiForProgress`).
- `mindfulQuotes()` → the bundled `quotes[]` (**50** entries in `mindful_timer_quotes.json`) **plus 9 hard-coded paired quotes** appended in the impl (`_pairedQuotes`) → 59 total. `randomQuote()` picks one at random.

### 8.3 Animations

`plans/presentation/widgets/animated_emoji.dart` renders a glyph with one of **14** `EmojiAnimation` styles (wire tokens are the upper-case enum names in the JSON, e.g. `"BREATHING"`). `EmojiAnimation.fromWire` is case-insensitive and falls back to a calm `breathing` for unknown/extended values, so a bad server token never breaks the UI. Each style is a closed-form transform driven by one repeating controller; per-motion loop durations:

| Duration | Animations |
|---|---|
| 650 ms | `shake`, `quaking` |
| 900 ms | `flash`, `chaos` |
| 3200 ms | `lumber` |
| 2400 ms | `fly`, `slide` |
| 1800 ms (default) | `breathing`, `scanning`, `melting`, `bouncing`, `waving`, `sinking`, `glow` |

All content widgets honour reduce-motion (still glyph / plain text).

### 8.4 Mount status (accuracy note)

`ContentRepositoryImpl` is DI-registered and the widgets (`AnimatedEmoji`, `QuoteBox`) are built and reduce-motion-aware, but **they are not currently mounted on a live screen** — no presentation code calls `emojiPlacement`/`randomQuote`, and the emoji/quote assets aren't yet wired into the Pause/Conscious surfaces. The live plan surfaces today are the **`SessionDialogs`** and the **dashboard hero ring** (§9). Treat the emoji-band/quote engine as **built infrastructure awaiting a screen (planned / follow-up)**, not a live feature. (`daily_limit_emoji_bands.json` / `DAILY_LIMIT_HERO` is consumed by the daily-limit feature — see [07-daily-limit-scheduler.md](07-daily-limit-scheduler.md).)

---

## 9. Presentation surfaces (live today)

| Widget | File | Role |
|---|---|---|
| `SessionDialogs` | `plans/presentation/widgets/session_dialogs.dart` | The single global frosted `GlassDialog` for **Pause**, **Conscious**, and **Unblock**. Pause / Conscious are dual-state: a setup/picker view when idle, a live action view (Resume / Turn off) while a session runs (`_ConsciousDialog` keys on `settings.activePlan == BlockingPlan.curious`). **`showUnblock`** (`_UnblockDialog`) is a one-shot circular 2–20 count picker (mirrors `_PauseDialog`, seeded at `SessionDefaults.unblockDefault`) that arms via `setOneReel(count:)`. |
| `CountdownRing` | `plans/presentation/widgets/countdown_ring.dart` | Read-only circular gauge (`SleekCircularSlider`, no handle) used by the dashboard hero. `progress` = **remaining fraction for Pause, banked fraction for Conscious**. Shares `pauseSliderAppearance` with the interactive Pause picker so both look identical. |
| `AnimatedDigitTimer` | `plans/presentation/widgets/animated_digit_timer.dart` | Per-digit crossfading `mm:ss` countdown in the hero. |
| `CountdownCubit` | `plans/presentation/countdown_cubit.dart` | Generic 1 Hz countdown to a target `DateTime`; emits remaining `Duration` clamped at zero. |
| `ConsciousCubit` | `plans/presentation/conscious_cubit.dart` | Mirrors the native bank (§5.5). Provided app-wide in `main.dart`; watched by the dashboard. |
| `ReelSessionCubit` | `plans/presentation/reel_session_cubit.dart` | Mirrors the native One Reel / Unblock session (§7.3). Provided app-wide in `main.dart`; watched by the dashboard `ModeSelector`. |
| `AnimatedEmoji`, `QuoteBox` | `plans/presentation/widgets/{animated_emoji,quote_box}.dart` | Built content widgets (§8.3/§8.4) — not yet mounted. |

The dashboard (`lib/features/dashboard/presentation/dashboard_tab.dart` + `widgets/command_center_card.dart`) is the caller: it opens `SessionDialogs.showPause/showConscious/showUnblock`, builds the hero `SessionCountdown` from either the live `PauseSession.remainingIn` or `ConsciousState` (`progress`/`banked`), and relabels `BlockingPlan.curious → 'CONSCIOUS'`. Plan selection is a **horizontally-scrolling row of pill cells** (`widgets/mode_selector.dart`) inside one dark rounded glass strip — icon-over-label, the selected cell filling with a `primary→secondary` gradient pill — in fixed enum order Block All, Conscious, Pause, One Reel, Unblock (the last two use `AppIcon.oneReel`/`unblock`). (This reverted the earlier vertical bounded-scroll board; all five pills are feature-tour targets.) One Reel arms directly at count 1; Unblock opens `showUnblock`; the active One Reel / Unblock pill shows a small accent **"N" remaining badge** read from `ReelSessionCubit`'s `reelSession.remaining`. `ModeSelector`'s public API no longer takes a `baseMode` param (the "BASE" chip was dropped; `_ModeSection` no longer passes it). Per-plan hero stats (today's reel / block counts) render through a single `StatStrip` (`widgets/stat_pill.dart`), now **uncontained** (bare pills, no card chrome).

---

## 10. End-to-end flows (summary)

**Start a Pause (4 min):** `SessionDialogs` picker → `SettingsCubit.startPause(4 min)` → `AppSettings` gets `activePlan = baseMode` + `PauseSession(cooldown=0, planToResume=baseMode)` → `_commit` persists + pushes `{activePlan: <base wire>, pauseUntil: pauseEnd}` → native gate `now < pauseUntil` suspends reel/web blocking (whole-app locks stay enforced) → at `pauseEnd`, native gate re-arms and the 1 Hz UI ticker settles the session back to the **base mode**.

**Turn on Conscious:** `SessionDialogs` → `SettingsCubit.enterConscious()` → `setPlan(curious)` (records `baseMode = curious`) → `_commit` pushes `{activePlan: CURIOUS, consciousEarnDivisor, consciousMaxBankMs}` (stored **verbatim**, no bank reset) → then `enterConscious` `await`s `resetConsciousBank` → `CommandHandler` empties the bank (store + the service's cache, via `onConsciousBankReset()`) + `reload()` → `syncConscious()` starts the 1 Hz accountant → each tick accrues while abstaining / drains 1:1 while watching, booting reels on empty → `consciousState` events stream to `ConsciousCubit` for the hero/dialog. (An auto-revert *into* Conscious skips the reset, so the bank survives.)

**Turn on One Reel / Unblock (allow 3):** `ModeSelector` (Unblock → `showUnblock` picker) → `SettingsCubit.setOneReel(count: 3)` → `_commit` pushes `{activePlan: ONE_REEL, reelAllowance: 3}` (persists the target, does *not* reset the count) → then the imperative `armReelSession(3)` → `CommandHandler` sets `reelAllowance=3`, `activePlan=ONE_REEL`, `resetReelSession()` (count→0), calls `service.armReelSession()` (zero runtime dwell state, reload, emit) → in the detector loop `allowReelOrBlock` counts a reel once it's watched ≥ 2s: reels 1–3 each increment `reelsConsumed`; a fresh 4th reel (allowance spent) is blocked and emits `reelSessionState {blocked:true}` → `SettingsCubit._onReelSession` flips `activePlan → baseMode` (**auto-revert**, §7.4); events also stream to `ReelSessionCubit`.

---

## Source files

- `lib/features/blocking/plans/domain/entities/sessions.dart` — `PauseSession`, `SessionPhase` phase math.
- `lib/features/blocking/plans/domain/entities/session_defaults.dart` — Pause slider + Conscious tuning constants.
- `lib/features/blocking/plans/domain/entities/conscious_state.dart` — Conscious bank snapshot entity.
- `lib/features/blocking/plans/domain/entities/reel_session_state.dart` — One Reel / Unblock session snapshot entity (`consumed`/`allowance`/`blocked`/`active`, `remaining`).
- `lib/features/blocking/plans/domain/entities/emoji_band.dart` — `EmojiAnimation`, `EmojiItem`, `EmojiSet`, `EmojiPlacement`, `EmojiPlacementId`.
- `lib/features/blocking/plans/domain/entities/mindful_quote.dart` — `MindfulQuote`.
- `lib/features/blocking/plans/domain/repositories/content_repository.dart` — content interface.
- `lib/features/blocking/plans/data/repositories/content_repository_impl.dart` — bundled/offline content impl (memoized, safe-degrade).
- `lib/features/blocking/plans/presentation/conscious_cubit.dart` — native bank mirror.
- `lib/features/blocking/plans/presentation/reel_session_cubit.dart` — native One Reel / Unblock session mirror.
- `lib/features/blocking/plans/presentation/countdown_cubit.dart` — generic 1 Hz countdown.
- `lib/features/blocking/plans/presentation/widgets/session_dialogs.dart` — Pause + Conscious dialogs.
- `lib/features/blocking/plans/presentation/widgets/countdown_ring.dart` — hero gauge + shared appearance.
- `lib/features/blocking/plans/presentation/widgets/animated_digit_timer.dart` — per-digit countdown.
- `lib/features/blocking/plans/presentation/widgets/animated_emoji.dart` — 14 emoji animations.
- `lib/features/blocking/plans/presentation/widgets/quote_box.dart` — animated quote card.
- `lib/features/blocking/shared/domain/entities/enums.dart` — `BlockingPlan` (`curious`/`CURIOUS`), `SessionPhase`.
- `lib/features/blocking/shared/domain/entities/app_settings.dart` — plan state, `baseMode` (sticky base plan), `reelAllowance`, `effectiveNativePlan`, `nativePauseUntil`, pause derivation, legacy migration.
- `lib/features/blocking/shared/presentation/settings_cubit.dart` — plan state machine, `baseMode` recording, Pause ticker + base-mode revert, One Reel / Unblock auto-revert (`reelSessionStream` sub, `_onReelSession`), `enterConscious` (+ `resetConsciousBank`) / `stopConscious`, `setOneReel`.
- `lib/features/blocking/shared/data/repositories/engine_repository_impl.dart` — `pushSettings` derivation (+ `reelAllowance`), `resetConsciousBank`, `consciousStream`/`consciousCurrent`, `armReelSession`/`reelSessionStream`/`reelSessionCurrent`.
- `lib/features/dashboard/presentation/dashboard_tab.dart` — plan surfaces, `_statusLabel` (`curious → 'CONSCIOUS'`), dialog + `ModeSelector` wiring (`setOneReel`).
- `lib/features/dashboard/presentation/widgets/command_center_card.dart` — `SessionCountdown`, hero ring, `StatStrip`.
- `lib/features/dashboard/presentation/widgets/mode_selector.dart` — horizontal pill-scroll plan picker (Block All / Conscious / Pause / One Reel / Unblock); active reel pill shows a `reelSession.remaining` badge; no `baseMode` param.
- `lib/features/dashboard/presentation/widgets/stat_pill.dart` — `StatStrip` hero stat row.
- `lib/core/constants/app_constants.dart` — bundled content asset paths, `EngineTimings`.
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` — Conscious accountant (`syncConscious`, `accountConscious`, `consciousSnapshot`), One Reel / Unblock gate (`allowReelOrBlock`, `armReelSession`, `reelSessionSnapshot`), Pause `pauseUntil` gate, constants.
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` — bank/pause persistence, `resetConsciousBank`, `reelAllowance`/`reelsConsumed`/`resetReelSession`.
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` — `pushSettings` handler (plan stored verbatim, no bank reset), explicit `resetConsciousBank` command, `consciousState` query, `armReelSession`/`reelSessionState`.
- `assets/content/curious_emojis.json` — `EMOJI_CURIOUS_PLAN` band.
- `assets/content/pause_emojis.json` — `EMOJI_PLAN_PAUSE` band.
- `assets/content/pause_countdown_pause_emojis.json` — `EMOJI_PLAN_PAUSE_COUNTDOWN` band.
- `assets/content/pause_countdown_cooldown_emojis.json` — `EMOJI_PAUSE_COUNTDOWN_COOLDOWN` band (percent).
- `assets/content/mindful_timer_quotes.json` — mindful quotes.
- `assets/content/daily_limit_emoji_bands.json` — `DAILY_LIMIT_HERO` band (consumed by daily-limit feature).
