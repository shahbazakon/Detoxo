# App Blocker & Web Blocklist

Two sibling features under `lib/features/limits/` that let the user block whole
apps and distracting websites:

- **App Blocker** (`limits/app_blocker`) — a user-managed list of whole apps to
  lock, plus a management surface that also drives the curated built-in feed
  toggles.
- **Web Blocklist** (`limits/web_blocker`) — a searchable website blocklist
  (custom domains + one-tap popular sites), two category toggles (adult content,
  "web versions of blocked apps"), a live stats dashboard, and the only path in
  this pair that is **natively enforced** today.

Both follow the feature-first Clean Architecture used across Detoxo
(`data` / `domain` / `presentation`, Cubits, `get_it` locator `sl`, persistence
through `lib/core/storage/local_store.dart`). The `limits` public barrel
(`lib/features/limits/limits.dart`) re-exports only the two domain entities and
their repository contracts — other features never reach into `data/` or
`presentation/`.

> **Enforcement at a glance.** The Web Blocklist is enforced by the native
> `WebBlockEngine` (address-bar host read → back press). The App Blocker is
> **UI + persistence only**: its package list is never enforced natively on its
> own. The single way an App Blocker entry reaches the engine is indirectly —
> the Web Blocklist can *derive* website rules from enabled App Blocker apps
> (see [App→domain derivation](#appdomain-derivation)). The project README marks
> "native enforcement of app/web/usage" as a follow-up; the web host-blocking
> path described below is the live subset of that.

---

## Part A — App Blocker

### Entity: `AppBlockEntry`

`lib/features/limits/app_blocker/domain/entities/app_block_entry.dart`

An `Equatable` value object for one fully-blocked app.

| Field | Type | Notes |
|---|---|---|
| `packageName` | `String` | Identity; unique within the list. |
| `appName` | `String` | Friendly label (falls back to the package). |
| `enabled` | `bool` | Default `true`. |
| `lockAction` | `AppLockAction` | `OVERLAY` / `CLOSE_APP` (default) / `LOCK_SCREEN`. |
| `dailyLimitMinutes` | `int` | Default `0`; modeled here, consumed by the sibling `daily_limit` feature. |

`AppLockAction` is defined in the shared enums
(`lib/features/blocking/shared/domain/entities/enums.dart`); each variant carries
a wire token, and `fromWire` falls back to `closeApp`. JSON round-trips via
`fromJson` / `toJson`; there is no separate `toWire` because the entry is not
pushed to the channel directly.

### Repository & persistence

- Contract: `app_blocker/domain/repositories/app_block_repository.dart` — just
  `load()` / `save(entries)`.
- Impl: `app_blocker/data/repositories/app_block_repository_impl.dart` —
  JSON-encodes the list into `LocalStore` under `StoreKeys.appBlocklist`
  (`"app_blocklist"`). Simple key-value; no Hive/Room/ContentProvider.

### Cubit

`app_blocker/presentation/app_block_cubit.dart` — `Cubit<List<AppBlockEntry>>`.
Straight CRUD over the repository:

- `load()` — hydrate from storage.
- `add(packageName, appName)` — trims, ignores empty or duplicate packages,
  defaults `appName` to the package when blank.
- `toggle(index, enabled:)` / `removeAt(index)`.
- `_commit(entries)` — `emit` then `save` (optimistic UI, persist after), then
  fires the optional `onChanged` callback fire-and-forget.

No engine push happens here directly — the cubit takes an optional
`onChanged` callback, which the screen wires to `syncWebBlocklist` (see the
web blocker below) so the app-derived web rules never go stale when the app
list changes. A failed sync never blocks the app-blocker UI.

### Screen

`app_blocker/presentation/app_block_screen.dart` — titled **"Block apps"**. It
is a *management* surface unifying two systems that **enforce differently**:

1. **Custom apps** — the whole-app locks above (`AppBlockCubit`). An "Add app"
   FAB opens the shared installed-app picker (`core/widgets/app_picker_sheet.dart`
   → `showAppPickerSheet`): a searchable, multi-select bottom sheet of the
   device's launchable apps (icon + name + package, from
   `EngineRepository.installedApps()` — cached process-wide). Apps already in the
   custom list show an "Added" pill and can't be re-picked, and **protected
   apps can't be blocked** (one role per app): catalog packages show an
   "Auto-protected" pill, user-protected packages (loaded from
   `ProtectedAppsRepository` before the sheet opens) a "Protected" pill. A
   manual name + package form remains as the fallback for apps the system hides
   (work profiles, engine unavailable) — it enforces the same `unavailable` map
   (inline hint + disabled confirm), keeps any list selections when confirming,
   and configures the package field like the web-blocker host field
   (`autocorrect: false`, URL keyboard). A refresh button beside the search
   field rescans (`installedApps(refresh: true)`) for mid-session installs.
   Each selection routes through `cubit.add`, which returns an
   `AppBlockAddResult` (`added | invalid | sensitive | duplicate`, EVO-006):
   garbage package ids never persist (`isValidPackageName`,
   `lib/core/utils/package_name.dart`), and sensitive catalog packages
   (`ProtectedAppCatalog.byPackage`) are refused regardless of entry path. The
   toast tells the truth — **"Added X"** (not "Blocked": custom locks record
   intent, enforcement is the follow-up below) counts only landed adds, and an
   all-refused batch shows the refusal reason as a warning instead. Each saved
   row shows the app's real device icon (from the cached scan; letter-tile
   fallback), an enable toggle and a delete button; when the custom list is
   empty the section is hidden entirely (the FAB is the entry point).
2. **Apps & feeds** — the curated, install-aware catalog of built-in feed
   surfaces. This section is driven by the *blocking* feature's global
   `TargetsCubit` (install-aware target list) and `SettingsCubit`
   (`enabledPlatformIds`), **not** by `AppBlockCubit`. Toggling a row here calls
   `SettingsCubit.togglePlatform(...)` — i.e. it flips a `platforms_config.json`
   platform on/off, which the native reel/short detection path honors. Browsers
   are split into their own sub-group. A search field appears once there are more
   than 8 targets.

Only the `AppBlockCubit` is route-scoped (`BlocProvider` in the screen);
`TargetsCubit` and `SettingsCubit` are global (created in `main.dart`).

Like the web blocker, the screen carries no intro paragraph: the app-bar
`InfoButton` explains the feed-vs-whole-app split, and section labels use the
shared `SectionHeader` / `InlineHint` from `core/widgets/common_widgets.dart`.

The practical takeaway: adding a *custom app* records intent but has no native
enforcer wired in this build; toggling a *curated feed* takes effect immediately
through the existing reel/short detection engine (see
[03-detection-engine.md](03-detection-engine.md) and the blocklist/settings docs).

---

## Part B — Web Blocklist (Dart)

### Entity: `WebBlockEntry`

`web_blocker/domain/entities/web_block_entry.dart`

| Field | Type | Notes |
|---|---|---|
| `pattern` | `String` | The host (`youtube.com`); also the entry's `id`. |
| `matchType` | `WebMatchType` | `DOMAIN` (default) / `EXACT` / `WILDCARD`. |
| `enabled` | `bool` | Default `true`. |
| `blockMode` | `BlockingMode` | Persisted; default `PRESS_BACK`. **Not** sent to native — the web path always presses back (see below). |
| `pausedUntil` | `DateTime?` | Optional per-entry pause window. |
| `displayName` | `String?` | Friendly label; falls back to `pattern`. |
| `source` | `WebBlockSource` | `CUSTOM` / `POPULAR` / `ADULT` / `APP_DERIVED`. |
| `brandColor` | `int?` | ARGB for the leading badge. |
| `createdAt` | `DateTime?` | Newest-first ordering. |

Derived getters: `label` (display name or pattern) and
`isActive == enabled && (pausedUntil == null || pausedUntil.isBefore(now))`.

Serialization is `toJson()` / `fromJson()` — the full persistence shape. The
minimal `{pattern, matchType[, pausedUntil]}` wire payload is built by
`syncWebBlocklist` (there is no `toWire()` on the entity: the wire list also
contains alias and app-derived patterns that never exist as entries). Enable
state, source and colors stay Dart-side; **the per-site pause window crosses
the wire** (EVO-012) so native enforces expiry itself — a paused site re-arms
even if the app is never reopened. `blockMode` was removed from the entity
(dead: native hardcodes `PRESS_BACK`; `fromJson` ignores the legacy key).
`isActiveAt(now)` is the clock-injectable form of `isActive`.

`WebBlockSource` lives in `web_blocker/domain/entities/web_block_source.dart`;
`WebMatchType` in the shared enums
(`blocking/shared/domain/entities/enums.dart`).

### Domain validation

`web_blocker/domain/utils/domain_validator.dart` — `DomainValidator.normalize()`
accepts `example.com`, `www.example.com`, `sub.example.com`, trailing-dot FQDNs
(`example.com.`) and full URLs (`https://user:pass@example.com:8080/path?x#y`),
then strips scheme → path → query/fragment → userinfo → port → leading `www.` →
trailing dot, lowercases, and validates against a host regex (dotted labels +
a 2–24 char TLD). Rejects empty input, spaces, scheme-only text, and
single-label hosts.

`DomainValidator.check(input, existingPatterns, ignoring:)` is the single
validate+dedupe rule (returns `(host, error)`), shared by the add/edit sheet's
inline validation and the cubit — the error strings live only here.

Deliberate limits, mirrored from the native matcher's `HOST_GUARD` (accepting
more here would create entries native can never match): ASCII hostnames only
(no IDN — users can paste the punycode form), no IPv4/IPv6 literals.

### Curated catalogs

- **`PopularSites`** (`web_blocker/domain/entities/popular_site.dart`) — 15
  one-tap sites (YouTube, Instagram, Facebook, X, Reddit, Netflix, Prime Video,
  Disney+, Twitch, TikTok, Pinterest, Snapchat, LinkedIn, Quora, Tumblr). Each
  `PopularSite` lists every reachable host; `primaryDomain` (`domains.first`) is
  what gets stored, and the rest are **aliases**. `aliasesFor(primaryDomain)`
  returns the non-primary hosts. Rationale: a `DOMAIN` match on `youtube.com`
  already covers `m.`/`www.` subdomains, so only cross-registrable aliases like
  `youtu.be`, `twitter.com` (for X), or `fb.com` need their own rule.
- <a id="appdomain-derivation"></a>**`AppDomainCatalog`**
  (`web_blocker/domain/entities/app_domain_catalog.dart`) — a static
  `packageName → [domains]` map (~17 entries) used by the "Block sites for
  blocked apps" toggle. The cubit reads the *existing* App Blocker list and
  derives web rules from it, so the **package list itself never crosses the
  channel** — only the resulting domains do.

### Persistence & stats

- **Blocklist:** `web_block_repository_impl.dart` → `LocalStore` key
  `StoreKeys.webBlocklist` (`"web_blocklist"`), JSON list of full entries. A
  corrupt blob loads as `[]` instead of throwing (fail-soft: the screen and the
  boot-time sync keep working, the raw value is only overwritten by a user
  edit, and native keeps enforcing its own persisted copy regardless).
- **Stats:** `web_block_stats_repository_impl.dart` → `LocalStore` key
  `StoreKeys.webBlockStats` (`"web_block_stats"`). This repo is the Dart mirror
  of website-block analytics:
  - `load()` reads the stored `{date, today, total, hosts{}}` blob and rolls the
    `today` counter to `0` when the stored calendar date is stale.
  - `watch()` subscribes to the native EventChannel and reacts to
    `ChannelEvents.webBlocked` events: it bumps a **per-host tally** (so the
    dashboard can show "most blocked"), then prefers the engine-supplied
    `today`/`total` counters (falling back to a local increment if omitted),
    persists, and yields a fresh `WebBlockStats`.
  - `WebBlockStats` (`web_block_stats.dart`) carries `totalBlocked`,
    `blockedToday`, `mostBlockedHost`, and a derived `focusMinutesSaved` using
    the app-wide 30 s/block heuristic (`secondsSavedPerBlock`).

The native `ConfigStore` keeps its **own** authoritative today/total web-block
counters (survives the UI process dying); the Dart repo mirrors those and adds
the per-host breakdown that native does not track.

### Cubit & state

`web_blocker/presentation/web_block_cubit.dart` +
`web_block_state.dart`. The cubit owns the blocklist plus two settings toggles
and is constructed with five dependencies: `WebBlockRepository`,
`SettingsRepository`, `AppBlockRepository`, `WebBlockStatsRepository`, and
`EngineRepository`.

Key operations:

- `load()` — hydrates entries + stats + `blockAdultWebsites` /
  `blockWebsitesForBlockedApps` from settings, subscribes to the stats stream,
  and **re-syncs native** via `_pushAll()` on every (re)entry.
- `addCustom(domain)` — validates + dedupes, appends a `CUSTOM`
  `WebBlockEntry`.
- `togglePopular(site)` — adds/removes by `primaryDomain`; a new entry carries
  the site name, `POPULAR` source, and brand color.
- `toggleEntry` / `removeEntry` / `editEntry` — CRUD; only custom entries are
  editable (re-validated + deduped).
- `setBlockAdult(value:)` / `setBlockForApps(value:)` — persist to
  `AppSettings` and **`_engine.pushSettings(next)`**; `setBlockForApps` also
  re-runs `_pushAll()` because the derived app→domain rules changed.
- `search` / `clearError`.
- `_commit(entries)` — `emit` → `_repo.save` → `_pushAll()`.

<a id="pushall"></a>**`syncWebBlocklist` — building the native payload.** The
merged blocklist is assembled and shipped in one place:
`web_blocker/domain/web_block_sync.dart` (exported via the `limits.dart`
barrel). It reads persisted state (`WebBlockRepository.load()`,
`SettingsRepository.load()`, `AppBlockRepository.load()`) rather than cubit
state — safe because every caller persists before pushing.

**Best-effort by contract:** the whole body is wrapped in try/catch →
`AppLogger.e` (non-fatal Crashlytics). A failed `load()` — e.g. a corrupt
blocklist blob, which `WebBlockRepositoryImpl.load()` deliberately rethrows —
**aborts the push**: native keeps enforcing its last-good persisted list (the
fail-safe direction). Pushing `"[]"` on corruption would be interpreted by
native as an intentional clear and wipe it. The catch also keeps the
fire-and-forget call sites from booking `fatal: true` pseudo-crashes via
`PlatformDispatcher.onError`. Its three callers:

1. `WebBlockCubit._pushAll()` (a one-line delegate) — screen load and every
   list mutation.
2. The splash `_bootstrap()` (fire-and-forget, next to
   `syncProtectedAppsAtBoot`) — repairs Dart→native drift at every launch,
   e.g. after "Reset app data", without the Web Blocker screen ever opening.
3. `AppBlockCubit.onChanged` (wired in `app_block_screen.dart`) — so
   adding/toggling/removing a blocked app immediately updates the derived
   web rules.

The algorithm:

1. For each **enabled** entry add `{pattern, matchType}`; a live per-site
   pause adds `pausedUntil` (epoch ms) — native skips the rule until then and
   re-arms it at expiry (EVO-012). Disabled entries are omitted.
2. For any enabled **popular** entry, add each
   `PopularSites.aliasesFor(pattern)` as a `DOMAIN` rule (`putIfAbsent`, so
   explicit rules win); aliases inherit the primary's pause window.
3. If `blockWebsitesForBlockedApps` is on, load the App Blocker list and, for
   each **enabled** app, add every `AppDomainCatalog.domainsFor(package)` as a
   `DOMAIN` rule.
4. Serialize the deduped `pattern → matchType` map to a JSON array of
   `{pattern, matchType}` and call `engine.pushWebBlocklist(json)`.

Because active-state, pausing, alias expansion, and app-derivation are all
resolved here, the native side only ever sees a flat, already-filtered rule
list. In practice every rule the cubit emits is `matchType: "DOMAIN"` — nothing
in the UI creates `EXACT`/`WILDCARD` entries today, though both the entity and
the native engine support them.

### Screen

`web_blocker/presentation/web_block_screen.dart` — titled **"Website
blocker"**. `BlocConsumer` surfaces transient `error` strings as a toast; no
`buildWhen` — stats ticks are rare while this screen is visible (blocks happen
while the user is in the browser), so the full rebuild beats selector
plumbing. The stats `Row` deliberately does **not** use
`CrossAxisAlignment.stretch`: inside the `ListView` its height is unbounded,
and stretch hands the cards an infinite height constraint — layout aborts the
frame (blank body) and then `!semantics.parentDataDirty` spams every frame.
Latent since inception, first triggered 2026-08-17 by the first on-device
`webBlocked` stat while the screen was open; guarded by
`test/web_block_screen_semantics_test.dart`. Layout:

- **Stats dashboard** (`_StatsSection`) — three `StatCard`s (Blocked today,
  Total blocked, Focus saved [min]) plus a "Most blocked" line; only shown
  when `state.hasStats`.
- **Protection** — two `AppToggleTile`s: "Block websites of blocked apps"
  (`setBlockForApps`) and "Block adult content (18+)" (`setBlockAdult`).
- **Popular sites** — `AppChip`s from `PopularSites.all` split across two rows
  inside one horizontal `SingleChildScrollView` (both rows scroll together);
  selected state driven by `state.activePopularIds`. A trailing "Add website"
  chip closes the second row and opens the same add sheet as the FAB. Tapping a
  chip whose domain already exists as a *custom* entry upgrades that entry to
  the popular one in place (never deletes the user's entry).
- **Your blocklist** — searchable rows (search appears past 8 entries, matching
  the sibling screens, and stays visible while a query is active so the filter
  can always be cleared); each row has an enable toggle (with a
  site-named `semanticLabel`), a pause/resume button (EVO-012: a
  `GlassBottomSheet` of 5/15/30/60-minute chips; paused rows show "Paused until
  HH:MM" and native re-arms the block at expiry), an edit button (custom only —
  also enforced in `editEntry`), and delete; all tooltips carry the site name
  for TalkBack. The primary empty state is an `EmptyState` with an "Add
  website" CTA. Add/edit use a `GlassBottomSheet` with inline feedback from the
  shared `DomainValidator.check` rule; the sheet awaits the cubit commit and
  only announces success ("Blocked X") after persist + push landed — a failed
  save reverts the optimistic list and shows the error toast instead.

On-screen explanatory copy is kept to a minimum: the app-bar `InfoButton`
(tap-to-open `Tooltip`) carries the feature explanation instead of an intro
paragraph and per-toggle subtitles.

---

## The `pushWebBlocklist` contract

**Wire payload** (from `_pushAll`, JSON string argument `json`):

```json
[
  {"pattern": "youtube.com", "matchType": "DOMAIN"},
  {"pattern": "youtu.be",    "matchType": "DOMAIN"}
]
```

**Dart side.** `EngineRepository.pushWebBlocklist(String json)` →
`EngineChannel.pushWebBlocklist` →
`invokeVoid(ChannelMethods.pushWebBlocklist, {'json': json})` over MethodChannel
`com.errorxperts.detoxo/commands`. The whole engine layer no-ops off Android via
`PlatformCapabilities`. The two category toggles ride the **`pushSettings`**
command instead (`blockAdultWebsites`, `blockWebsitesForBlockedApps` fields).

**Native side** (`channels/CommandHandler.kt`):

- `"pushWebBlocklist"` → fail-safe like `pushProtectedApps`: a null or
  non-JSON-array `json` arg is a **no-op, never a wipe** (clearing requires an
  explicit `"[]"`); a valid payload is stored
  (`store.webBlocklistJson = json`) and applied via
  `DetoxoAccessibilityService.instance?.reload()`.
- `"pushSettings"` → among other fields, sets `store.blockAdultWebsites` /
  `store.blockWebsitesForBlockedApps`, then `reload()`.

`ConfigStore` (`engine/ConfigStore.kt`) persists these to SharedPreferences file
`detoxo_engine_prefs` (`webBlocklistJson`, `blockAdultWebsites`,
`blockWebsitesForBlockedApps`) plus the separate web-block counters
(`recordWebBlock(dateKey)` / `webBlockStats()`), kept distinct from the
reel-block counter. On `reload()` the service re-applies both:

```kotlin
webEngine.setBlocklist(store.webBlocklistJson)
webEngine.setAdultEnabled(store.blockAdultWebsites)
```

> Note: `blockWebsitesForBlockedApps` is persisted natively but the derivation is
> entirely Dart-side — native just receives the already-merged domain rules via
> `pushWebBlocklist`, so the native flag is effectively informational.

---

## Native enforcement

### `WebBlockEngine`

`android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt` —
the host matcher. Holds a `@Volatile` in-memory `List<Rule(pattern, type)>` and
an optional adult-domain `HashSet`.

- `setBlocklist(json)` — parses the pushed `[{pattern,matchType}]`, lowercasing
  and trimming patterns, dropping blanks; `matchType` defaults to `"DOMAIN"`.
- `setAdultEnabled(on)` — **lazily loads** the bundled asset
  `adult_domains.txt.gz` (gzipped, `#`-comment-aware) into a `HashSet` only while
  the toggle is on, and frees it when off (so it costs no heap otherwise). A
  missing/unreadable asset degrades to an empty set (adult blocking no-ops).
- `hasAnyRules()` — cheap guard for the accessibility hot path (any rules, or
  adult enabled with a non-empty set).
- `matchHost(host, fullUrl?)` — returns true when the host is blocked:

| `matchType` | Rule |
|---|---|
| `DOMAIN` (default) | `host == pattern` **or** `host.endsWith("." + pattern)` — covers subdomains. |
| `WILDCARD` | glob (`*` = any run) — regex precompiled once at `parse()`, never on the per-event path. |
| `EXACT` | matches only when a `fullUrl` is supplied and equals the pattern. |

A rule with a future `pausedUntil` (epoch ms, from the wire — EVO-012) is
skipped until `System.currentTimeMillis()` passes it, then matches again with
no push needed. The `DOMAIN` subdomain check is allocation-free
(`isSubdomainOf` — no `"." + pattern` concat per event).

If adult blocking is on, the host is additionally walked up its parent labels
(`foo.bar.example.com → bar.example.com → example.com`), returning true on any
set hit.

> All matching is **host-based**. Android accessibility can read the address bar
> but cannot see network traffic, so there is no URL/path/network-level
> filtering. `EXACT` needs a full URL that the current flow never provides, so it
> is effectively unused today.

### `BrowserUrlExtractor`

`android/app/src/main/kotlin/com/errorxperts/detoxo/engine/BrowserUrlExtractor.kt` —
stateless host extraction from a browser's accessibility tree.

- **`isBrowser(pkg)`** — membership test over `KNOWN_BROWSERS` (the mapped
  address-bar packages **plus** extra recognized browsers that rely on the
  generic fallback, e.g. Lightning, Adblock Browser, Puffin, Tor). This gates the
  whole web branch in the service.
- **`extractHost(root, pkg, maxNodes)`** — two-stage:
  1. **Fast path:** a per-browser address-bar resource-id lookup
     (`URL_BAR_IDS`, ~22 packages incl. Chrome/Beta/Dev/Canary, Samsung
     Internet, Firefox/Fenix, Edge, Brave, Opera/Mini/GX, DuckDuckGo, Kiwi,
     Vivaldi, Mi/Mini, AOSP, UC, Yandex, Ecosia) via
     `findAccessibilityNodeInfosByViewId`.
  2. **Generic fallback:** a bounded DFS (`ArrayDeque`, capped at `maxNodes` =
     `MAX_NODES` = 12000, same cap as reel detection) over `EditText` /
     `url`-ish nodes, extending coverage to effectively any browser.

  Both stages **skip focused nodes**: a focused address bar means the user is
  typing, so half-typed hosts never trigger a back press mid-edit. Once
  navigation commits, focus moves to the page and the load's content-change
  events re-run extraction on the then-unfocused bar, so the block still
  fires. Ceiling: a browser that kept its bar focused after page load would
  never be blocked — none of the mapped ones do.
- **`normalizeHost(raw)`** — lowercases, rejects strings containing spaces
  (search queries / "Search or type URL" placeholders), strips
  scheme/path/query/fragment/port and leading `www.`, and validates against a
  registrable-host guard (min length 4, must contain a dot).

### Flow in the accessibility service

`accessibility/DetoxoAccessibilityService.kt`. The web branch sits in
`onAccessibilityEvent`, after the master-enable and pause-window gates and the
per-package `THROTTLE_MS` (150 ms) throttle:

```kotlin
if (BrowserUrlExtractor.isBrowser(pkg)) {
    if (webEngine.hasAnyRules() &&
        (event.type == WINDOW_STATE_CHANGED || event.type == WINDOW_CONTENT_CHANGED))
        handleBrowser(pkg)
    return   // a browser carries no reel surfaces
}
```

`handleBrowser(pkg)`:

1. `extractHost(root, pkg, MAX_NODES)`; bail if null.
2. `webEngine.matchHost(host)`; if not blocked, remember it as `lastUrlByPkg` and
   return.
3. **Per-host debounce:** if the host equals the last one and it is within
   `BLOCK_DEBOUNCE_MS` (1200 ms), skip — so a content-change storm on the same
   blocked page yields at most one back press.
4. `store.recordWebBlock(dateKey())`, read `(today, total)`, and post a
   `webBlocked` event: `{host, mode:"PRESS_BACK", today, total}`.
5. `pressBackWithRateLimit()` (global back action, rate-limited by
   `BACK_RATE_LIMIT_MS` = 1100 ms), then a short **"$host blocked by Detoxo"
   toast** (EVO-011) so the bounce is attributable rather than looking like a
   browser glitch.

The block **mode is always `PRESS_BACK`** here — only
`{pattern, matchType[, pausedUntil]}` crosses the channel, so native has no
per-entry mode to honor. The log line never includes the host (browsing data
must not reach logcat); the `webBlocked` event is consumed by
`WebBlockStatsRepositoryImpl.watch()` to update the Dart-side dashboard.

---

## Enforcement status (this build)

| Capability | Status |
|---|---|
| App Blocker — custom whole-app locks | UI + persistence only; **no native enforcer** (planned / follow-up). |
| App Blocker — curated feed toggles | Live, via existing reel/short detection (`SettingsCubit.togglePlatform`). |
| Web Blocklist — custom + popular domains | **Live** — native `WebBlockEngine` + address-bar read → back press. |
| Web Blocklist — "block sites for blocked apps" | Live; domains derived Dart-side from enabled App Blocker apps. |
| Web Blocklist — adult category | Live when `adult_domains.txt.gz` is bundled; no-ops if the asset is missing. |
| Web match types beyond `DOMAIN` (`WILDCARD`/`EXACT`) | Supported natively; not produced by the current UI. |

The README summary table conservatively groups "native enforcement of
app/web/usage" as a follow-up; the web host-blocking path above is the shipped
subset of that work.

## Source files

- `lib/features/limits/limits.dart`
- `lib/features/limits/app_blocker/domain/entities/app_block_entry.dart`
- `lib/features/limits/app_blocker/domain/repositories/app_block_repository.dart`
- `lib/features/limits/app_blocker/data/repositories/app_block_repository_impl.dart`
- `lib/features/limits/app_blocker/presentation/app_block_cubit.dart`
- `lib/features/limits/app_blocker/presentation/app_block_screen.dart`
- `lib/core/widgets/app_picker_sheet.dart` (shared installed-app picker)
- `lib/core/platform_channels/installed_app.dart`
- `lib/core/utils/package_name.dart` (package-id validation)
- `lib/features/limits/web_blocker/domain/entities/web_block_entry.dart`
- `lib/features/limits/web_blocker/domain/entities/web_block_source.dart`
- `lib/features/limits/web_blocker/domain/entities/web_block_stats.dart`
- `lib/features/limits/web_blocker/domain/entities/popular_site.dart`
- `lib/features/limits/web_blocker/domain/entities/app_domain_catalog.dart`
- `lib/features/limits/web_blocker/domain/repositories/web_block_repository.dart`
- `lib/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart`
- `lib/features/limits/web_blocker/domain/utils/domain_validator.dart`
- `lib/features/limits/web_blocker/domain/web_block_sync.dart`
- `lib/features/limits/web_blocker/data/repositories/web_block_repository_impl.dart`
- `lib/features/limits/web_blocker/data/repositories/web_block_stats_repository_impl.dart`
- `lib/features/limits/web_blocker/presentation/web_block_cubit.dart`
- `lib/features/limits/web_blocker/presentation/web_block_state.dart`
- `lib/features/limits/web_blocker/presentation/web_block_screen.dart`
- `lib/features/blocking/shared/domain/entities/enums.dart` (`WebMatchType`, `AppLockAction`, `BlockingMode`)
- `lib/core/constants/channel_constants.dart` (`pushWebBlocklist`, `webBlocked`)
- `lib/core/platform_channels/engine_channel.dart` (`pushWebBlocklist`)
- `lib/core/storage/local_store.dart` (`appBlocklist`, `webBlocklist`, `webBlockStats` keys)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/WebBlockEngine.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/BrowserUrlExtractor.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (`handleBrowser`, web branch)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt` (`pushWebBlocklist`, `pushSettings`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ConfigStore.kt` (web-block persistence + counters)
