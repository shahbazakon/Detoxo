# EVO-047 — Name the browsers Detoxo cannot cover

- Status: approved
- Tier: 2 (enhancement) — requires explicit per-proposal approval
- Feature: `lib/features/limits/web_blocker` + native `engine/BrowserUrlExtractor.kt`, `channels/CommandHandler.kt`
- Commit: 190042a
- Date: 2026-09-04
- Effort: M

## Why

Web blocking is gated on a closed allowlist. `DetoxoAccessibilityService.kt:639`:

```kotlin
if (BrowserUrlExtractor.isBrowser(pkg)) {
```

and `BrowserUrlExtractor.kt:84`:

```kotlin
fun isBrowser(pkg: String): Boolean = KNOWN_BROWSERS.contains(pkg)
```

A browser outside that set is never read, so **the user's blocklist and the 18+
filter are both entirely inert in it** — with no signal anywhere in the UI. The
generic DFS fallback does not help: it only widens coverage *within*
`KNOWN_BROWSERS`, because the gate runs first.

The gap is not hypothetical. `assets/config/platforms_config.json` flags
`com.jio.web` as `"browser": true` and the App Blocker renders it under
**Browsers** — while `KNOWN_BROWSERS` has never contained it. Detoxo lists a
browser it enforces nothing in. `org.mozilla.focus` is likewise absent.

The copy has been corrected to "any **supported** browser" (Tier-1 finding 2),
which stops the app lying. It does not tell the user *which* browsers those are,
so a user whose only browser is unsupported still sees a screen that looks like
it is protecting them.

## Expected user impact

The Website blocker screen names the installed browsers it cannot cover:

> **Not covered: Firefox Focus, Jio Web.** Detoxo can't read their address bar,
> so blocking doesn't apply there.

A user can then uninstall it, switch browsers, or add it to the App Blocker —
all three are real remedies, and none is available today because the problem is
invisible. This is the same truthful-state line as EVO-013 (honest protection
status when the OS kills the service), EVO-014 (`unknown` permission states),
EVO-022 (counter states) and EVO-036 (suppression without its grant): Detoxo
does not claim protection it cannot deliver.

## Technical complexity

- **Native:** one new read-only channel method. `PackageManager.queryIntentActivities`
  for `ACTION_VIEW` + `http`/`https` is the definitive "is a browser" test, and
  the manifest **already declares both `<queries>` intents** ("Web browsers
  (package visibility for the website blocker)"), so there is no new permission
  and no `QUERY_ALL_PACKAGES`.
- **Dart:** channel key + `EngineChannel` method + `EngineRepository` contract +
  a notice widget on the Website blocker screen.
- **Contract change:** one new method key `unsupportedBrowsers`. No storage key,
  no schema migration, no event.

## Performance impact

None on the accessibility hot path — this never runs in `onAccessibilityEvent`.
The query runs on screen open only, and follows the repo's established
off-platform-thread pattern (`ioExecutor.execute { … mainHandler.post { … } }`,
`CommandHandler.kt:440-455`), because resolving activities and loading labels
costs 100s of ms on busy devices. Dart tolerates a null result and renders
nothing.

## Business value

`docs/info_docs/01-product-overview.md` sells in-the-moment intervention. A
silent total bypass is the worst failure mode for that promise: the user
believes they are protected and is not. Naming the gap converts an invisible
defect into a solvable one, and keeps the store-listing claim defensible.

## Rejected alternative

**Resolve installed browsers at runtime and union them into `KNOWN_BROWSERS`,
making coverage genuinely universal.** Strictly better for the user and it would
make the original "any browser" copy true. Rejected for now because it points the
unmapped-browser DFS — up to `MAX_NODES` = 12000 binder reads per qualifying
event — at arbitrary apps whose trees nobody has measured, and the audit could
not judge that cost from code. It is the right follow-up **after** a device
measurement, and this proposal is the honest interim: tell the truth now, widen
coverage once the cost is known.

## Rollback

Delete the channel method, its key, the repository leg and the notice widget.
Nothing is persisted and no wire payload changes shape, so a revert is clean and
older builds are unaffected.

## Implementation Plan

### Current state

`android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt:440-455`

```kotlin
"installedPackages" -> {
    ioExecutor.execute {
        val packages = queryLaunchablePackages()
        mainHandler.post { result.success(packages) }
    }
}
```

`lib/features/limits/web_blocker/presentation/web_block_state.dart` has no field
for this; `web_block_cubit.dart:37` `load()` fetches entries, settings and stats.

### Target state

- `ChannelMethods.unsupportedBrowsers = 'unsupportedBrowsers'`.
- Native returns `List<Map>` of `{packageName, label}` — installed activities
  resolving `ACTION_VIEW`+http/https, minus `BrowserUrlExtractor.isBrowser`,
  minus Detoxo's own package, deduped by package, sorted by label.
- `WebBlockState.unsupportedBrowsers` (`List<String>` of labels, default
  `const []`), filled by `load()`.
- A `NoticeCard`-style warning on the Website blocker screen when non-empty.

### Repo conventions to follow

- Off-thread + `mainHandler.post`, exactly as `installedPackages`
  (`CommandHandler.kt:440-447`).
- `EngineChannel._invoke<List<dynamic>>` with a null-tolerant decode and
  `AppLogger.e` on a bad payload — copy `installedApps`
  (`engine_channel.dart:336-346`).
- UI from `lib/core/design_system/components/`; no raw `AlertDialog`/`SnackBar`.
- Cubit not in get_it; state is a plain Equatable class.

### Steps

1. Add the key to `ChannelMethods` in `lib/core/constants/channel_constants.dart`.
2. Add the `"unsupportedBrowsers"` arm + `queryUnsupportedBrowsers()` helper to
   `CommandHandler.kt`.
3. Add `unsupportedBrowsers()` to `EngineChannel` and to the `EngineRepository`
   contract + its impl.
4. Add the state field, fill it in `WebBlockCubit.load()` (failure ⇒ empty, never
   fatal — the blocklist must still render).
5. Render the notice on the Website blocker screen.
6. Test: cubit populates the field; a channel failure leaves it empty.

### Boundaries

Do not add `QUERY_ALL_PACKAGES`. Do not widen `KNOWN_BROWSERS` — that is the
rejected alternative and needs its own measurement first. Do not touch the
`isBrowser` gate or any engine budget. If the code at the cited lines has drifted
from commit 190042a, STOP and report.

### Validation

- [ ] `bash tool/dev.sh precommit` passes
- [ ] `tool/boundaries_baseline.txt` line count ≤ before
- [ ] New logic has a test in the repo pattern
- [ ] Invariants grep clean
- [ ] Production readiness: no new manifest permission, works offline, channel
      failure path is non-fatal and logged
- [ ] `/docs-sync` — `06`, `18`, and `info_docs/02` §15 + `04`
