# PIN Lock & Biometrics

The **access_protection** feature is Detoxo's app-level lock: a PIN that gates
opening the app and changing protected settings, an escalating retry-lockout
ladder, optional biometric / device-credential unlock (`local_auth`), and
**Smart Auto Lock** — re-locking on return from the background plus
FLAG_SECURE Recents privacy (§10).

> **There is no recovery channel, deliberately.** An earlier build shipped an
> email-OTP flow backed by a hardcoded `_devOtp = '000000'` that `validateOtp`
> accepted against *any* address — a one-tap bypass of the app's core commitment
> device, in release builds, with the code printed on screen. It was removed
> rather than wired to a backend: with the PIN stored only on-device and no
> account behind it, any code the client can accept is a bypass available to
> anyone holding the phone, not a recovery. See §7. It is a self-contained Clean-Architecture feature — `data / domain /
presentation` under `lib/features/access_protection/` — and the rest of the app
touches it only through `PinCubit`, the public barrel
(`access_protection.dart`), and the `requirePin` / `PinGuard` helpers.

> Scope note: this is a *soft* lock enforced in the Flutter UI. It guards Detoxo's
> own screens; it is not the same thing as the native accessibility/Device-Admin
> enforcement described in [03-detection-engine.md](03-detection-engine.md) and
> [13-onboarding-permissions.md](13-onboarding-permissions.md). The `LOCK_APP`
> block mode *reuses* this PIN screen conceptually, but native enforcement of it
> is a follow-up (the engine currently degrades `LOCK_APP` to a back press).

---

## 1. Layer map

| Layer | File | Responsibility |
|-------|------|----------------|
| domain / entity | `domain/entities/pin_config.dart` | `PinConfig` (persisted state) + `AutoLockTimeout` + `AutoLockPolicy` (resume re-lock) + `PinLockoutPolicy` (the ladder) |
| domain / hashing | `domain/pin_hasher.dart` | `PinHasher` — salted SHA-256 for custom PINs |
| domain / contract | `domain/repositories/pin_repository.dart` | `PinRepository` interface (load / save / secure-screen / screen-off + elapsed-realtime queries) |
| data | `data/repositories/pin_repository_impl.dart` | secure-storage persistence, legacy plaintext migration, channel calls for FLAG_SECURE + screen-off + `monotonicNow()` (via `EngineChannel.monotonicNow`) |
| presentation / state | `presentation/pin_cubit.dart` | `PinCubit` — setup, verify, lockout, biometrics |
| presentation / gate | `presentation/pin_gate.dart` | `requirePin()` + `PinGuard` — how other features demand the PIN |
| presentation / relock | `presentation/pin_auto_relock.dart` | `PinAutoRelock` — lifecycle observer that re-locks on resume |
| presentation / UI | `presentation/pin_lock_screen.dart` | the full-screen keypad lock |
| presentation / UI | `presentation/pin_setup_screen.dart` | configure / disable the lock |
| presentation / UI | `presentation/pin_help_sheet.dart` | "Forgot PIN?" — explains there is no reset |
| barrel | `access_protection.dart` | exports **only** `PinConfig` + `PinRepository` |

`PinType` and `PinScope` live in the shared blocking enums file
(`lib/features/blocking/shared/domain/entities/enums.dart`) because they carry
wire tokens used in persisted JSON.

---

## 2. `PinConfig` — the persisted state

`PinConfig` (an `Equatable`) is the single object `PinCubit` emits and the
repository round-trips to secure storage. Fields:

| Field | Type | Notes |
|-------|------|-------|
| `type` | `PinType` | `none` (default), `custom`, `date`, `time` (also `deviceDefault`, modeled but not offered — see §3) |
| `secretHash` | `String` | salted SHA-256 of a **custom** PIN; empty for date/time/none |
| `salt` | `String` | random salt behind `secretHash`; empty otherwise |
| `secretLength` | `int` | digit count of a custom PIN — stored so the lock screen can draw the right number of dots and auto-submit **without ever holding the secret** |
| `scopes` | `Set<PinScope>` | which sections the PIN guards |
| `retryCount` | `int` | cumulative failed attempts (persisted, drives the ladder) |
| `lockedUntil` | `DateTime?` | end of the current cooldown window (null = not locked) — the **wall-clock leg** |
| `lockoutElapsedUntilMs` | `int?` | monotonic (`elapsedRealtime`) expiry of the lockout (EVO-015) — the **monotonic leg** a Settings clock change can't move. Null on legacy configs / when the native clocks were unavailable |
| `lockoutBootCount` | `int?` | the `Settings.Global.BOOT_COUNT` the monotonic leg was anchored in — the leg is trusted only while the live boot count still matches |
| `biometricEnabled` | `bool` | whether fingerprint/face/device-credential unlock is allowed |
| `autoLock` | `AutoLockTimeout` | resume re-lock timing (default `m1`); see §10 |
| `secureScreen` | `bool` | FLAG_SECURE — hide in Recents + block screenshots (default `false`) |

Derived getters / checks:

- `isConfigured` → `type != PinType.none`.
- `isLockedOut` → `lockedUntil != null && lockedUntil.isAfter(now)` — wall-clock
  only, and now documented as the lock screen's **display approximation**
  (countdown text, dialogs). Enforcement does **not** use it alone: a Settings
  clock bump would defeat it.
- **`lockoutRemainingAt(now, {elapsedMs, bootCount})`** — the clock-robust
  truth (EVO-015), pure. The monotonic leg is authoritative **in both
  directions while valid** — `monotonicLegValid` requires both readings
  present, the lockout to carry a monotonic leg, and `bootCount ==
  lockoutBootCount` (same boot, by identity — not a heuristic). Cross-boot or
  null readings fall back to the wall clock (`lockedUntil`).
  **`isLockedOutAt(...)`** is `lockoutRemainingAt(...) > Duration.zero`.
  `ponytail:` reboot **plus** clock-forward together still clears a lockout —
  the wall leg is all that survives a reboot; accepted ceiling.
- **`PinCubit.reconciled(config, now, {elapsedMs, bootCount})`** — pure
  reconciliation, driven by `reconcileLockout()` from `load()`, lock-screen
  entry and `verify()`: an expired lockout (by the authoritative clock) is
  cleared, and while the monotonic leg is valid a wall stamp that drifted >2s
  from `now + remaining` is rewritten — so the lock screen's cheap wall-clock
  rendering can never disagree with enforcement (a forward clock jump
  re-shows the countdown instead of answering the correct PIN with
  "Incorrect PIN"; a backward jump releases the keypad after the true
  remaining time).
- `guards(scope)` → `scopes.contains(scope)`.

`copyWith` has one non-obvious parameter: **`clearLockout`**. Because `lockedUntil`
is nullable, an ordinary `copyWith(lockedUntil: null)` can't distinguish "leave
it" from "clear it", so passing `clearLockout: true` forces `lockedUntil = null`
**and nulls both monotonic-leg fields**. This is how a successful verify wipes
the cooldown.

**JSON:** `toJson`/`fromJson` use each enum's `wire` token (`type` and each
`scope`), and `lockedUntil` is stored as `millisecondsSinceEpoch`;
`lockoutElapsedUntilMs` / `lockoutBootCount` are **additive** int keys
(older configs simply read them as null). This is the exact shape written under
the secure key `pin_config`.

---

## 3. PIN types

`PinType` (enum, with wire tokens):

| Value | Wire | Offered in UI | Behaviour |
|-------|------|---------------|-----------|
| `none` | `NONE` | yes (= "no lock", the default) | lock disabled |
| `custom` | `CUSTOM` | yes | user-chosen 4–10 digits; stored as salted hash |
| `date` | `DATE` | yes | derived from the clock: `ddMMyyyy` (8 digits), **changes daily** |
| `time` | `TIME` | yes | derived from the clock: `HHmm` (4 digits), **changes each minute** |
| `deviceDefault` | `DEVICE_DEFAULT` | no | modeled for wire compat; not selectable |

**Derived PINs (date/time) store no secret at all** — no salt, no hash,
`secretLength = 0`. `PinCubit.derivedPin(type, now)` computes the expected
value live from the clock — the single source of truth consumed by both the
matcher (`PinCubit.matches`) and the setup screen's live preview:

```dart
PinType.date => '${_two(now.day)}${_two(now.month)}${now.year}', // ddMMyyyy
PinType.time => '${_two(now.hour)}${_two(now.minute)}',          // HHmm
```

They are convenience / "obscurity" locks (anyone who knows the trick can unlock),
which is why the setup screen surfaces a live preview ("Right now that is …") and
a hint that the value rotates. Custom PINs are the only credential that is a real
secret.

`PinCubit.expectedLength` tells the lock screen when an entry is complete so it can
auto-submit: `custom → secretLength`, `date → 8`, `time → 4`, else `4`.

---

## 4. PIN scopes

`PinScope` (enum, wire tokens) — the sections a PIN can guard:

| Value | Wire | Status |
|-------|------|--------|
| `app` | `DETOXO_APP` | **live** — ask for the PIN at launch |
| `settings` | `SETTINGS_APP` | **live** — ask before disabling blocking / resetting data / changing the PIN |
| `planSwitch` | `PLAN_SWITCH` | retired — pruned on setup; lock-screen copy still handled |
| `detoxoSettings` | `DETOXO_SETTINGS` | retained for wire compat; lock-screen copy handled |
| `appLocker` | `APP_LOCKER` | retired — pruned on setup; lock-screen copy still handled |

The setup screen exposes only `app` and `settings` (`_supportedScopes`). Any other
scope persisted by an older build is **filtered out on load and never re-saved**,
so the enum can keep the retired tokens for backward-compatible deserialization
without resurrecting dead toggles.

---

## 5. Hashing — `PinHasher`

`PinHasher` (an `abstract final class`, static-only) keeps custom PINs out of
plaintext storage:

- `newSalt()` — 16 cryptographically-random bytes from `Random.secure()`,
  `base64Url`-encoded for JSON-safe storage.
- `hash(salt, secret)` — `sha256(utf8('$salt:$secret'))` as a hex string.
- `verify(salt, expectedHash, entry)` — returns `false` if either `salt` or
  `expectedHash` is empty (so a misconfigured custom PIN can *never* unlock),
  otherwise `hash(salt, entry) == expectedHash`.

Date/Time PINs never pass through the hasher — there is nothing to hash.

> Note: this is a single unsalted-iteration SHA-256 (no PBKDF2/Argon key
> stretching). It is adequate against casual inspection of on-device storage for a
> 4–10 digit PIN, not against a determined offline brute-force. Hardening the KDF
> is a reasonable follow-up.

---

## 6. `PinCubit` — behaviour

`PinCubit extends Cubit<PinConfig>`; the emitted state *is* the `PinConfig`. It is
constructed with a `PinRepository` and an optional `LocalAuthentication` (defaults
to a fresh `LocalAuthentication()`, injectable for tests). Registered app-wide (see
§10).

### Setup / teardown

- `load()` — loads from the repo, **re-applies the FLAG_SECURE window state**
  (window flags die with the activity; every recreation path re-runs the splash,
  which awaits this), then emits.
- `setup({type, secret, scopes, biometricEnabled, autoLock, secureScreen})` —
  for `custom`, mints a salt and hashes the secret and records `secretLength`;
  for date/time it stores empty salt/hash and `secretLength = 0`. Saves, pushes
  the FLAG_SECURE state, and emits.
- `disable()` — saves and emits `const PinConfig()` (i.e. `type = none`),
  removing the lock entirely and clearing FLAG_SECURE.
- `lastScreenOff()` — proxies the native screen-off timestamp for
  `AutoLockTimeout.screenOff` (§10).

### Verification and the lockout ladder

`verify(entry)` is the core:

```
mono = lockedUntil == null ? null : await repo.monotonicNow()  // {elapsedMs, bootCount}?
if (lockedUntil != null) reconcile-and-emit(reconciled(state, now, mono))   // realign display
if (isLockedOutAt(now, mono)) return false;                    // clock-robust gate
if (matches(config, entry, now)) { retryCount=0, clearLockout; save+emit; return true; }
retries = retryCount + 1;
lockout = PinLockoutPolicy.lockoutFor(retries);
anchor  = lockout == null ? null : await repo.monotonicNow();  // lazy: common path pays nothing
updated = config.copyWith(clearLockout: true)        // drop any STALE monotonic leg first
            .copyWith(retryCount: retries,
                      lockedUntil: lockout == null ? null : now + lockout,
                      lockoutElapsedUntilMs: anchor == null ? null : anchor.elapsedMs + lockout,
                      lockoutBootCount: anchor?.bootCount);
save+emit(updated);
return false;
```

Enforcement therefore runs on `isLockedOutAt` with the native monotonic clock
(EVO-015) — `isLockedOut` alone is wall-clock and a Settings clock bump would
clear the ladder. A fresh lockout is **anchored to the monotonic clock** when
the read answered; the `clearLockout`-first dance matters because an escalating
lockout must never keep a *stale* monotonic leg (e.g. the elapsed read flaked
to null this time) — an already-expired old anchor would override the fresh
wall-clock lockout.

`retryCount` is **cumulative and persisted** — it is only ever reset by a correct
PIN or a completed recovery. Because both `retryCount` and `lockedUntil` (plus
the monotonic legs) live in secure storage, the escalation and any active
cooldown **survive an app restart**; force-quitting during a lockout does not
clear it — and changing the device clock no longer does either.

The match itself is `PinCubit.matches(config, entry, now)` — a static,
clock-injected `@visibleForTesting` method (the repo's pure-logic idiom), so
date/time matching is testable with a fixed clock.

**`PinLockoutPolicy.lockoutFor(retryCount)`** (in `pin_config.dart`) maps the
post-increment attempt count to a cooldown:

| Cumulative failed attempts | Lockout |
|----------------------------|---------|
| 1–5 | none |
| 6–8 | 30 seconds |
| 9–10 | 5 minutes |
| 11–15 | 1 hour |
| 16–20 | 4 hours |
| 21+ | 24 hours |

### Biometrics (`local_auth`)

- `canUseBiometrics()` — `isDeviceSupported() && canCheckBiometrics`; any
  `Exception` → `false`. Used to hide the biometric toggle where unsupported.
- `authenticateBiometric()` — guards on `canCheckBiometrics || isDeviceSupported`,
  then `authenticate(localizedReason: 'Unlock Detoxo', persistAcrossBackgrounding:
  true)`; any `Exception` → `false`.

> Behaviour to note: the biometric path does **not** consult `isLockedOut`. A
> successful fingerprint/face unlock succeeds regardless of an active retry
> cooldown — the ladder only gates the numeric keypad. Biometrics are gated only
> by `biometricEnabled` being set at setup.

> **Device credential is included.** `local_auth`'s `biometricOnly` defaults to
> `false`, so the OS sheet also accepts the device PIN/pattern/password. The
> setup toggle and lock-screen semantics are labeled "fingerprint or device
> credential" to say so honestly. A stale success is discarded: `_tryBiometric`
> fires the gate's unlock only while its route `isCurrent`, so a credential
> prompt completing under a newer route (e.g. the auto-relock) can't pop the
> wrong screen.

---

## 7. Persistence — `PinRepositoryImpl`

`PinRepositoryImpl` implements `PinRepository` over `LocalStore`'s **secure**
key-value API (`readSecret` / `writeSecret`, backed by `flutter_secure_storage`).
The whole `PinConfig` JSON is stored under `StoreKeys.pinConfig` (`'pin_config'`,
flagged `// secret`).

**Legacy migration.** `load()` handles installs that predate hashing and stored a
plaintext custom PIN under a `secret` key: if the config is `custom`, has no
`secretHash`, and a non-empty legacy `secret` is present, it hashes that secret
with a fresh salt, persists the migrated config, and returns it — so the plaintext
is never re-saved and never sits unhashed again.

**No recovery, and no `verifiedEmail`.** The repository is `load` / `save` only.
With recovery gone, storing a recovery address would be PII collected for nothing
and one more item to declare on the Play data-safety form, so the field was
dropped from `PinConfig` entirely. `fromJson` simply ignores the legacy
`verifiedEmail` key, so installs written by an older build load without migration
(covered by a test in `test/access_protection_test.dart`).

**The escape hatch is reinstalling.** Uninstalling clears
`flutter_secure_storage` along with the rest of app storage. That is deliberate
friction rather than a one-tap bypass, and it is what `PinHelpSheet`, the setup
screen and the FAQ all tell the user. If uninstall protection (device admin) is
on, it must be turned off first.

> ⚠️ Android auto-backup is enabled by default and could in principle restore the
> encrypted blob on reinstall. The Keystore key is not backed up, so the blob
> should be undecryptable — but **verify uninstall/reinstall actually clears the
> PIN on a real device**; if it survives, set `android:allowBackup="false"` or add
> a backup-exclusion rule.

---

## 8. UI

### `PinLockScreen` (`pin_lock_screen.dart`)

The full-screen keypad. One widget, three roles, selected by its callbacks:

| Role | Trigger | `onUnlocked` | `onCancel` |
|------|---------|--------------|-----------|
| **Launch gate** | routed to `/pin/lock` from splash | supplied by the router: resumes the gating order (permissions → home); a `null` falls back to `context.go(Routes.home)` | absent (forced) |
| **Inline guard** | `PinGuard` wraps a screen | reveals the child | `maybePop()` |
| **Action gate** | `requirePin()` pushes it | pops `true` | pops `false` |

Key behaviours:

- `PopScope(canPop: false)` — the system back gesture **never** dismisses it. A
  close (✕) affordance appears **only** when `onCancel` is provided (i.e. an
  optional in-app gate, never the launch gate).
- On mount, if `biometricEnabled`, it fires `authenticateBiometric()` via a
  post-frame callback (prompts immediately).
- `_onKey` appends a digit, ignores input past `expectedLength`, and auto-submits
  (`_attempt`) once the buffer is full. If locked, a keypress instead re-shows the
  lockout dialog.
- `_attempt` → `cubit.verify`; on success `_succeed` (success haptic + the role's
  unlock action); on failure it plays an error haptic + shake, shows "Incorrect
  PIN", clears the entry, and — reading the freshly-emitted state — pops the
  lockout dialog if a new cooldown just started.
- **Lockout UX is dual:** an inline `_LockoutText` ticks a live countdown
  (`formatCountdown`) driven by a 1 Hz timer (`_syncLockTimer`) that runs *only*
  while locked and re-enables the keypad the instant the window ends; plus a glass
  dialog ("Too many attempts. Please wait …") shown **once per distinct lockout
  window** (guarded by `_shownFor`) so repeated pokes and the 1 Hz rebuild can't
  spam it.
- Scope-specific copy (title/subtitle/icon) is provided for `app`, `settings`,
  `appLocker`, and `planSwitch`/`detoxoSettings`.
- The keypad is 1–9 then `[biometric] 0 [backspace]`: the bottom-left key is the
  fingerprint shortcut when `biometricEnabled`, otherwise empty. `_Dots` renders
  `expectedLength` progress dots (clamped 1–10).
- "Forgot PIN?" opens `PinHelpSheet` — an explanation, not an unlock. It never
  calls `_succeed`, so there is no path from this button into the app.

### `PinSetupScreen` (`pin_setup_screen.dart`)

Configure or turn off the lock. Loads the current `PinConfig` on init (filtering
scopes to `_supportedScopes = {app, settings}`) and probes `canUseBiometrics()` to
decide whether to show the biometric toggle.

Save validation (`_save`):

1. `type == none` → routes to `_turnOff` (confirm dialog then `disable()`; no-op if
   nothing was configured).
2. custom: PIN ≥ 4 digits, and PIN == confirm (both toast on failure).
3. at least one scope selected.
4. `setup(..., biometricEnabled: _biometric && _biometricAvailable, autoLock:
   _autoLock, secureScreen: _secureScreen)`, toast, pop.

When the **app** scope is selected, a **Smart Auto Lock** section appears: a
bottom-sheet radio picker for the auto-lock timeout (`_AutoLockPicker`, same
pattern as the PIN-type picker) and a "Hide screen in Recents" toggle
(labeled as also blocking screenshots — FLAG_SECURE does both). The biometric
toggle is labeled "Unlock with fingerprint or device credential".

The screen states inline that there is no reset and that a forgotten PIN means
reinstalling — shown *before* the user commits, not discovered afterwards.

The custom-PIN fields are digits-only, obscured, `maxLength: 10` (hint "Enter 4–10
digits"). Date/Time selections show a live derived-value preview instead of an
entry field. A bottom-sheet radio picker chooses among none / custom / date / time.

### `PinHelpSheet` (`pin_help_sheet.dart`)

A glass bottom sheet titled **"Forgot your PIN?"**. It states that Detoxo cannot
unlock the PIN for anyone, explains why (the PIN never leaves the device, there is
no account), names reinstalling as the way to start over, and notes that uninstall
protection must be switched off first. One **Got it** button; it dismisses and
nothing else.

It replaced a 299-line 3-step OTP flow. `maskEmail` and `_ReadOnlyField` went with
it — neither had any other caller.

---

## 9. Demanding the PIN — `requirePin` & `PinGuard`

`pin_gate.dart` is the boundary other features use; they never construct
`PinLockScreen` directly.

```dart
// Action gate — await it at the trigger of a protected action.
if (await requirePin(context, PinScope.settings)) {
  // proceed; false means the user cancelled or failed
}
```

- **`requirePin(context, scope)`** reads `PinCubit.state`; if the lock isn't
  configured *or* doesn't guard `scope`, it returns `true` immediately (no
  prompt). Otherwise it pushes a full-screen `PinLockScreen` on the **root**
  navigator and resolves to whether the user unlocked.
- **`PinGuard(scope:, child:)`** wraps a whole screen: it shows `child` immediately
  when the scope isn't guarded, otherwise renders the lock inline and pops back out
  on cancel.

Because both consult `isConfigured` + `guards(scope)` first, adding a `requirePin`
call is safe even when no PIN is set — it's a pass-through until the user opts in.

---

## 10. Smart Auto Lock — resume re-lock & Recents privacy

**`AutoLockTimeout`** (enum in `pin_config.dart`, wire tokens): `never`
(`NEVER` — the pre-auto-lock behavior, locked only on cold start),
`immediately`, `s15`, `s30`, `m1` (default), `m5`, and `screenOff`
(`SCREEN_OFF` — stay unlocked while the screen stays on; re-lock once it has
turned off during the absence). Configs stored by older builds have no
`autoLock` key and upgrade to `m1` via `fromJson`.

**Decision** — `AutoLockPolicy.shouldRelock({config, pausedAt, now,
lastScreenOffMillis})`, pure and unit-tested: false unless the lock is
configured and guards `PinScope.app`; `screenOff` compares the native
screen-off stamp against the pause stamp; timed options compare elapsed
background time against the timeout.

**Mechanism** — `PinAutoRelock` (in `main.dart`, wrapping
`MaterialApp.router`) is a `WidgetsBindingObserver`:

- Stamps `_pausedAt` on **`paused` only** — biometric and permission prompts
  surface as `inactive` (and `hidden` precedes `paused`), so stamping those
  would re-lock during in-app system sheets.
- On `resumed`, consumes the stamp, queries `lastScreenOff` only for the
  `screenOff` option, and when `shouldRelock` says yes pushes a **forced
  `PinLockScreen` on the root navigator**
  (`router.routerDelegate.navigatorKey`) — the same idiom as `requirePin`, so
  navigation state, open dialogs and sheets survive underneath and the lock's
  `PopScope` blocks system back.
- **Never double-locks**: `PinLockScreen.appGateVisible` (a static visibility
  counter incremented only by forced app-scope gates — the launch gate and the
  relock) is checked before and after the async gap; backgrounding at the lock
  itself pushes nothing new.

**Recents privacy** — the `secureScreen` flag drives the `setSecureScreen`
channel command (`CommandHandler.kt` → `FLAG_SECURE` on the activity window).
It is applied at three choke points — `PinCubit.load()` / `setup()` /
`disable()` — so it survives activity recreation (splash always awaits
`load()`) and always clears when the lock is turned off. FLAG_SECURE blanks
the Recents card **and** blocks screenshots/`adb screencap`; note for QA: the
`detoxo-auto-test` screenshot layer records black frames while it is on
(default off).

**Screen-off tracking** — `MainActivity` registers an `ACTION_SCREEN_OFF`
receiver (`ContextCompat.registerReceiver`, `RECEIVER_NOT_EXPORTED`) and keeps
a `@Volatile` wall-clock stamp in its companion, read back via the
`lastScreenOff` command. In-memory only: process death cold-starts through the
splash gate anyway. Known ceilings (marked `ponytail:` in code): wall-clock
comparison skews if the user changes the clock, and API-34 broadcast deferral
can deliver one late screen-off (a single missed relock that self-heals).

**Reboot** — auto-lock after reboot needs no code: unlock state lives only in
memory, so any cold start (reboot included) passes through the splash launch
gate.

---

## 11. Wiring & integration

- **DI** (`lib/core/di/injector.dart`): `registerLazySingleton<PinRepository>(() =>
  PinRepositoryImpl(sl(), sl()))` (resolving `LocalStore` + `EngineChannel`).
- **Provider** (`lib/main.dart`): `BlocProvider(create: (_) =>
  PinCubit(sl<PinRepository>()))` — one app-wide cubit. `_RouterState` wraps
  `MaterialApp.router` in `PinAutoRelock(router: _router, ...)` (§10).
- **Routes** (`lib/core/navigation/routes.dart` + `app_router.dart`):
  `pinSetup = '/pin/setup'` → `PinGuard(scope: settings, child: PinSetupScreen())`
  — the route itself is gated, so every entry point (settings tile, drawer
  shortcut) passes the same guard; `pinLock = '/pin/lock'` → `PinLockScreen`
  with a router-supplied `onUnlocked` that resumes the splash's gating order
  (permissions → home), so PIN users can't skip the permissions gate.
- **Splash gating** (`lib/app/splash_screen.dart`): `pin.load()` runs in the boot
  `Future.wait`; routing order is **onboarding → PIN lock → permissions → home** —
  if `pin.isConfigured && pin.guards(PinScope.app)`, splash sends the user to
  `/pin/lock` before anything else.
- **Settings** (`lib/features/settings/presentation/settings_screen.dart`): the PIN
  toggle pushes `/pin/setup` (the route's own `PinGuard` asks for the PIN);
  the remaining protected mutations (turning the lock off from the master
  switch, disabling blocking, resetting data) are fenced behind
  `requirePin(context, PinScope.settings)`. The `LOCK_APP` block mode requires
  a configured PIN, so choosing it without one routes the user to PIN setup
  rather than selecting a mode that can't enforce anything.

---

## 12. Status / follow-ups

| Item | State |
|------|-------|
| Custom PIN storage | live — salted SHA-256, plaintext never persisted; legacy plaintext auto-migrated |
| Date/Time PINs | live — clock-derived convenience locks, no stored secret |
| Retry-lockout ladder | live — cumulative, persisted, survives restart |
| Clock-robust lockout (EVO-015) | live — enforcement anchored to `elapsedRealtime` + `BOOT_COUNT`, with display reconciled to the monotonic truth on load / lock-screen entry / verify. Ceiling: reboot + clock-forward together still clears (only the wall leg survives a reboot) |
| Biometric / device-credential unlock | live via `local_auth` (Android); bypasses the keypad lockout by design |
| Smart Auto Lock (resume re-lock) | live — `never`/`immediately`/15 s/30 s/1 m/5 m/`screenOff`; default 1 minute |
| Recents privacy (FLAG_SECURE) | live — opt-in toggle; also blocks screenshots (QA screenshots go black while on) |
| PIN recovery | **removed by design** — the `000000` dev backdoor is gone and no replacement is planned; reinstalling is the escape hatch (§7) |
| Hash KDF hardening | follow-up — single-round SHA-256 today |
| `LOCK_APP` native enforcement | follow-up — engine degrades to a back press (see [03-detection-engine.md](03-detection-engine.md)) |
| `deviceDefault` PIN type, `planSwitch` / `appLocker` scopes | modeled for wire compatibility; not offered / pruned in the UI |
| iOS | unsupported (the whole app is Android-only) |

---

## Source files

- `lib/features/access_protection/access_protection.dart`
- `lib/features/access_protection/domain/entities/pin_config.dart`
- `lib/features/access_protection/domain/pin_hasher.dart`
- `lib/features/access_protection/domain/repositories/pin_repository.dart`
- `lib/features/access_protection/data/repositories/pin_repository_impl.dart`
- `lib/features/access_protection/presentation/pin_cubit.dart`
- `lib/features/access_protection/presentation/pin_gate.dart`
- `lib/features/access_protection/presentation/pin_auto_relock.dart`
- `lib/features/access_protection/presentation/pin_lock_screen.dart`
- `lib/features/access_protection/presentation/pin_setup_screen.dart`
- `lib/features/access_protection/presentation/pin_help_sheet.dart`
- `lib/features/blocking/shared/domain/entities/enums.dart` (`PinType`, `PinScope`)
- `lib/core/storage/local_store.dart` (`StoreKeys.pinConfig`)
- `lib/core/widgets/common_widgets.dart` (`formatCountdown`)
- `lib/core/di/injector.dart` (`PinRepository` registration)
- `lib/main.dart` (`PinCubit` provider)
- `lib/core/navigation/routes.dart`, `lib/core/navigation/app_router.dart` (`/pin/setup`, `/pin/lock`)
- `lib/app/splash_screen.dart` (launch gating)
- `lib/features/settings/presentation/settings_screen.dart` (`requirePin` call sites)
- `lib/core/constants/channel_constants.dart`, `lib/core/platform_channels/engine_channel.dart` (`setSecureScreen`, `lastScreenOff`, `monotonicNow`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/MainActivity.kt` (screen-off receiver)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (`setSecureScreen`, `lastScreenOff`, `monotonicNow` branches)
