# 24 — Protected Apps (Privacy Exclusion)

> **One line:** a user-managed list of sensitive apps (banking, UPI, government
> identity, password managers, authenticators…) that Detoxo **completely
> ignores** — while one is on screen the engine does no counting, no browser URL
> reads, no tree walks, no blocking, no BACK presses, and nothing about the app
> is logged or sent anywhere.

The product principle: *Detoxo protects the user's attention without
compromising the user's privacy.* The user opens their bank, Detoxo quietly
steps aside; they return to Instagram, Detoxo quietly resumes.

---

## 1. The privacy guard — one decision point

Everything hangs off a single native predicate in
`DetoxoAccessibilityService`:

```kotlin
@Volatile private var protectedPkgs: Set<String> = emptySet()   // cached in reload()

/** THE privacy decision: Detoxo does nothing at all for a protected app. */
private fun isProtected(pkg: String?): Boolean = pkg != null && pkg in protectedPkgs
```

It is consulted at a fixed set of sites — nowhere else in the codebase may check
protected-ness, so there are no scattered package-name conditions:

| # | Site | What it prevents |
|---|---|---|
| 1 | `onAccessibilityEvent`, immediately after the `TYPE_WINDOW_STATE_CHANGED` block: `if (pkgProtected \|\| isProtected(foregroundPkg)) return` | All processing: counting, browser URL/text reads, node-tree walks, detection, blocking. |
| 2 | `activeWindowProtected(root)` — the **window anchor**, checked right after every `rootInActiveWindow` fetch (block path, counter pass, browser pass) | A tree whose root package is protected is never walked, even when `foregroundPkg` is stale (null after a service reconnect — no window-state event fires retroactively) or clobbered by a transient IME/system window. This is what makes split-screen and the reconnect-over-a-bank case safe. |
| 3 | `accountConscious()` (the 1 Hz Conscious accountant): freeze the bank, zero `lastReelAtMs`, return | The stale-watching BACK press. `WATCH_STALE_MS` (2.5 s) means a reel-app → bank switch could otherwise leave the accountant "watching"; when the bank hit 0 it would `pressBackWithRateLimit()` **inside the banking app**. |
| 4 | `performBackInternal()` — the choke point every BACK routes through — checks `foregroundPkg` **and** the window anchor | Any BACK (block, Conscious boot, Dart `performBack`) landing in a protected app, even from a timer that fired mid-switch or while an IME window (UPI PIN entry) holds `foregroundPkg`. |
| 5 | `killApp(pkg)` | A stale Dart-initiated kill (e.g. a daily-limit flow resolving late) killing a bank mid-transaction. |
| 6 | `lockScreen()` — `foregroundPkg` + window anchor | Locking the device mid-payment. |
| 7 | `ContentCounter.onProtectedForeground()` (called from the window-state branch) | The usage-gap heuristic (`USAGE_ACTIVE_GAP_MS` 12 s) bridging time spent inside a protected app and persisting it as monitored-app screen time. |

**Guard invariant (do not move it):** the event-path return sits *after* the
window-state block — so `foregroundPkg` still updates and the existing
`contentCounter.onForegroundChanged(pkg, isReelApp=false)` call hides the
counter bubble on entry — and *before* the counting pass, the master/pause
gates, the browser branch and the allowlist check. Protection therefore
overrides the monitored catalog: a protected app that also appears in
`platforms_config.json` is still ignored.

The window-state block also forces two things when the new foreground app is
protected: `lastReelAtMs = 0` (kills the Conscious stale-watching window
immediately) and `isReelApp = false` to the content counter (bubble hides, no
usage-time accrual).

Sites 3–7 are deliberate redundancy: with sites 1–2 in place they should be
unreachable for protected apps, but they fail closed if a future edit reorders
the pipeline. Cost is a few `HashSet` lookups per *action*, and two per event
plus one per root fetch — battery-irrelevant, and with an empty list the
behavior is identical to before.

**Push semantics (`CommandHandler` → `refreshProtectedPackages`)**: an absent or
malformed `packages` arg is a **no-op, never a wipe** — clearing protection
requires an explicit empty list; non-string elements are dropped. An unchanged
set skips the prefs write and the service refresh entirely, and a changed set
triggers only the cheap `refreshProtectedPackages()` (re-reads one set — no
detection-config re-parse, no Conscious/bubble re-sync; those remain `reload()`'s
job for the other push commands).

## 2. Transitions (the case that matters)

```
Instagram            → monitoring ACTIVE   (normal detection)
   ↓ opens bank
Banking app          → window-state event: foregroundPkg updated, bubble
                       hidden, lastReelAtMs zeroed → guard returns.
                       Accountant frozen. No overlay, no reads, no blocks.
   ↓ returns
Instagram            → next window-state event flows past the guard —
                       monitoring RESUMES automatically. No state machine,
                       no stored "previous mode" to restore.
```

Screen off produces no accessibility events (nothing to do); on unlock the
first window-state event re-evaluates naturally. Service restart / reboot:
`protected_packages` is a `StringSet` in `detoxo_engine_prefs`, and
`onServiceConnected → reload()` repopulates the volatile cache — protection
works with the Flutter process dead.

## 3. Data model & persistence

Catalog protection is **derived, not stored**. Dart persists only the user's
own additions; native owns only the minimum fact it needs.

- **Dart (Hive, `StoreKeys.protectedApps = 'protected_apps'`)** — JSON list of
  the user's **manual additions only**, as
  `ProtectedApp {packageName, appName, category, isEnabled, source}`.
  `category` ∈ `banking | payments | government | identity | password_manager |
  authentication | healthcare | insurance | investment | personal_data | other`;
  `source` ∈ `catalog | manual`. `ProtectedAppsRepositoryImpl.load()` returns
  `[]` for absent/unreadable data (nothing is lost — the catalog is implicit),
  salvages **per entry** (one unreadable row never discards the others — that
  would fail open), and filters out `source == catalog` rows (migration: early
  builds seeded catalog entries into storage; the next save rewrites without
  them).
- **Native (`detoxo_engine_prefs`, key `protected_packages`)** — a flat
  `Set<String>`: the **entire catalog plus enabled manual additions**
  (`protectedPackagesFor` in `protected_apps_boot.dart` is the single
  derivation, used by both the cubit and the boot sync). Names and categories
  never cross the channel (`pushProtectedApps`, see
  [18](18-platform-channel-contracts.md)).

Package id is the identity — display names change; package ids don't.

## 4. Catalog — always protected, never editable

`ProtectedAppCatalog` (domain, `AppDomainCatalog`-style const list, ~40
entries, India-weighted: YONO SBI/HDFC/iMobile…, Google Pay/PhonePe/Paytm/BHIM,
DigiLocker/mAadhaar/UMANG, Bitwarden/1Password/…, Google & Microsoft
Authenticator, ABHA/1mg, Kite/Groww/…, PolicyBazaar).

The **full catalog is always pushed**, installed or not: an uninstalled
package can never be foreground (so the extra entries cost nothing beyond set
size), and a sensitive app installed *later* is protected instantly with zero
sync logic. There is no first-run seeding, no install-scan dependency, and no
user control over catalog entries — no toggle, no removal. Users can only
**add** protected apps of their own (and delete those additions).

`syncProtectedAppsAtBoot(repo, engine)` (domain, fire-and-forget from the
splash `_bootstrap()`) pushes `protectedPackagesFor(manual)` every boot. This
is drift repair — the one real drift source is **"Reset app data"**, which
wipes Hive but not native prefs; until the next launch native *over*-protects,
which is the fail-safe direction.

## 5. UI & the self-bypass PIN gate

Settings → **Privacy** → **Protected apps** (`Routes.protectedApps`,
route-local `ProtectedAppsCubit(repo, engine, config)`): two sections —
**Your apps** (manual additions, delete only) and **Auto-protected**
(installed catalog apps, read-only cards with a category pill; when install
state is unknown the whole catalog renders). The FAB opens the shared
installed-app picker (`core/widgets/app_picker_sheet.dart` →
`showAppPickerSheet`): a searchable, multi-select bottom sheet of the device's
launchable apps (icon + name + package, from
`EngineRepository.installedApps()` — cached process-wide). Catalog apps show an
"Auto-protected" pill, manual entries a "Protected" pill, and custom-blocked
apps (loaded from the app_blocker feature's `AppBlockRepository` before the
sheet opens) a "Blocked" pill — an app has one role, protected *or* blocked —
all dimmed and unselectable. A manual name + package form remains as the
fallback for apps the system hides; it enforces the same `unavailable` map
(inline hint + disabled confirm), keeps any list selections when confirming,
and configures the package field like the web-blocker host field
(`autocorrect: false`, URL keyboard). A refresh button beside the search field
rescans (`installedApps(refresh: true)`) for mid-session installs. Every pick
routes through `cubit.addManual`, which returns a `ProtectedAddResult`
(`added | invalid | duplicate | alreadyCovered`, EVO-006): garbage package ids
never persist (`isValidPackageName`, `lib/core/utils/package_name.dart` —
case-preserving, `com.Slack` is real). The toast tells the truth: "Protected"
counts only landed adds; an all-refused batch shows the refusal reason
("Already protected automatically." / "That doesn't look like a package id.")
as a warning instead of celebrating a no-op. Saved rows (manual and
auto-protected) show real device icons from the cached scan, letter-tile
fallback. The blocker side mirrors the exclusion: its picker marks protected
packages and `AppBlockCubit.add` refuses catalog packages outright (see doc
06).

**PIN gate:** protection overrides the monitored catalog, so protecting
Instagram would bypass the user's own blocking. Adding a package that appears
in the blocking catalog (`ConfigRepository.loadBlockTargets()`) therefore
requires `requirePin(context, PinScope.settings)` — the same gate as turning
blocking off. With the multi-select picker the PIN is asked **once per batch**
when *any* picked package is monitored. Adding a bank has zero friction. The
gate **fails closed**: an empty monitored set (load pending or failed)
PIN-gates every add, and the "Add app" FAB is disabled until a load succeeds —
adding over a failed load would also overwrite stored protections, since state
would show an empty list. A failed load renders `EmptyState` + Retry and
always keeps whatever the repo returned.

## 6. Privacy guarantees (what is deliberately absent)

- No analytics event mentions a protected app: the block path
  (`onDetected` → local block log / Firebase `logBlockTriggered`) is
  unreachable behind the guard, and no new events were added.
- No native log line prints a protected package name.
- The list never leaves the device; the wire payload is enabled package names
  only, Dart → native.
- No polling, no UsageStats, no new permissions, no new services — the guard
  rides the existing accessibility event stream.

## 7. Known limitations

- **Package-based only.** A bank's *website* opened in Chrome is not covered
  (the browser is the foreground package). Protecting the browser itself works
  but also disables website blocking while it's open.
- **No Kotlin unit tests** (the repo has no native test infra): the guard
  placement is locked by this doc + `test/protected_apps_test.dart` pinning the
  wire contract, and verified manually on-device (protect a test app → no
  bubble, no BACK, no count; Instagram → bank → Instagram under Conscious
  within 2.5 s of a reel).
- The catalog is best-effort; package ids should be re-verified against Play
  Store listings when extending it.

## Source files

- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `lib/features/protected_apps/domain/entities/protected_app.dart`
- `lib/features/protected_apps/domain/entities/protected_app_catalog.dart`
- `lib/features/protected_apps/domain/protected_apps_boot.dart`
- `lib/features/protected_apps/domain/repositories/protected_apps_repository.dart`
- `lib/features/protected_apps/data/repositories/protected_apps_repository_impl.dart`
- `lib/features/protected_apps/presentation/protected_apps_cubit.dart`
- `lib/features/protected_apps/presentation/protected_apps_screen.dart`
- `lib/core/widgets/app_picker_sheet.dart` (shared installed-app picker)
- `lib/core/platform_channels/installed_app.dart`
- `lib/core/utils/package_name.dart` (package-id validation)
- `lib/core/constants/channel_constants.dart`
- `lib/core/platform_channels/engine_channel.dart`
- `lib/core/storage/local_store.dart`
- `lib/app/splash_screen.dart`
- `test/protected_apps_test.dart`
