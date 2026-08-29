# EVO-046 — PIN-gate protecting a browser, the same as protecting a blocked app

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/protected_apps` (+ the web blocker it silently disables)
- Commit: 190042a
- Date: 2026-09-04
- Effort: S

## Why

Protected apps exist so Detoxo reads nothing while a bank or password manager is
foreground. The guard is absolute — `DetoxoAccessibilityService.kt:524`:

```kotlin
if (pkgProtected || isProtected(foregroundPkg)) return
```

That `return` sits **above** the browser arm at `:639`, so protecting a browser
turns off the user's website blocklist *and* the 18+ filter in that browser,
completely and silently.

Adding a protection is PIN-gated only when the package is one Detoxo can block —
`protected_apps_cubit.dart:69-71`:

```dart
bool needsPinToAdd(String packageName) =>
    state.monitoredPackages.isEmpty ||
    state.monitoredPackages.contains(packageName.trim());
```

`monitoredPackages` is built from `_config.loadBlockTargets()`
(`protected_apps_cubit.dart:44`) — the **reel/shorts** catalog. Browsers carry no
reel surfaces (the service says so itself at `:637`), so no browser is ever in
that set, so `needsPinToAdd('com.android.chrome')` is `false`. Chrome can be
added with no PIN, and the Web Blocker screen goes on showing every entry
enabled and "Protection · 2".

The cubit's own comment (`:36-39`) states the rule this misses:

> Blocking-catalog packages, for the add-time PIN gate: protecting a monitored
> app is a self-bypass of blocking, so it costs the same PIN as turning blocking
> off.

Protecting a browser *is* a self-bypass of blocking. The principle is right; its
input set is too narrow.

## Expected user impact

Closes the cheapest bypass in the app. Someone who wants to defeat their own web
blocklist currently does it in three taps with no PIN and no visible change in
the Web Blocker screen. After this, it costs the settings PIN — exactly what
turning blocking off costs. Directly serves the in-the-moment intervention loop
(`docs/info_docs/01-product-overview.md`): a blocker whose enforcement can be
switched off without the credential that protects it is not enforcing.

Nothing changes for the intended use — banking and password-manager apps are not
browsers and stay one tap.

## Technical complexity

Dart only, one cubit and its state. No channel key, no storage key, no manifest
change, no schema migration. The browser list already exists natively
(`BrowserUrlExtractor.KNOWN_BROWSERS`) but is **not** reachable from Dart, so the
Dart side needs its own source of browser package names.

## Performance impact

None on the hot path — `needsPinToAdd` runs on a button tap in the Protected apps
screen, never in `onAccessibilityEvent`. The added set is built once per `load()`
alongside `monitoredPackages`.

## Business value

Protects the enforcement claim the store listing and FAQs make
(`docs/info_docs/01-product-overview.md`, "blocks distracting sites in any
supported browser"). Also protects the *protected-apps* feature's own story: it
should be a privacy guarantee, not an escape hatch.

## Rejected alternative

**Refuse to protect a browser at all.** Simpler, and it would close the bypass
completely rather than pricing it. Rejected because it breaks a legitimate case:
a user who does their banking in a browser has a real reason to want it
unreadable, and Detoxo's privacy promise should win over its blocking promise
when the two collide. Pricing the action at the PIN keeps both.

## Rollback

Delete the `browserPackages` field and restore the two-clause `needsPinToAdd`.
No persisted state, no wire change, nothing to migrate — a pure revert.

## Implementation Plan

### Current state

`lib/features/protected_apps/presentation/protected_apps_cubit.dart:44`

```dart
final targets = await _config.loadBlockTargets();
emit(
  ProtectedAppsState(
    isLoading: false,
    apps: apps,
    installed: installed,
    monitoredPackages: {for (final t in targets) t.packageName},
  ),
);
```

`:69-71`

```dart
bool needsPinToAdd(String packageName) =>
    state.monitoredPackages.isEmpty ||
    state.monitoredPackages.contains(packageName.trim());
```

### Target state

`needsPinToAdd` returns true for a blocking-catalog package **or** a known
browser. The browser set is a `static const Set<String>` on the cubit, seeded
from the packages `BrowserUrlExtractor.URL_BAR_IDS` + `KNOWN_BROWSERS` already
carry, with a comment naming that file as the source of truth so the two are
maintained together.

Fails closed exactly as today: an empty `monitoredPackages` (load not finished,
or failed) still costs the PIN for every add.

### Repo conventions to follow

- Pure predicate + test, per `test/protected_apps_test.dart` — it already has
  `needsPinToAdd is true only for blocking-catalog packages` and
  `needsPinToAdd fails closed before load and after a failed load`; extend that
  group rather than starting a new file.
- Cubit stays out of get_it (`lib/core/di/injector.dart` holds repos/services).

### Steps

1. Add `static const browserPackages = {...}` to `ProtectedAppsCubit`, with the
   comment pointing at `BrowserUrlExtractor.kt` as the native twin.
2. Widen `needsPinToAdd` to `|| browserPackages.contains(...)`.
3. Extend `test/protected_apps_test.dart` with a browser case and a
   non-browser/non-catalog case.

### Boundaries

Do not touch the native guard at `DetoxoAccessibilityService.kt:524` — it is
correct and deliberately absolute. Do not add a channel method to read the native
browser list; that is a bigger change than this earns. If the code at the cited
lines has drifted from commit 190042a, STOP and report — do not improvise.

### Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern
- [ ] Invariants grep clean
- [ ] Production readiness: no new permission, no persisted state, works offline
- [ ] `/docs-sync` — `docs/code_docs/24-protected-apps.md` + `info_docs/02` §13
