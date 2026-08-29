# M0 — Foundations: category catalog + usage signal layer

- Status: **shipped** — engineering doc [`code_docs/26-catalog-and-usage-signal.md`](../code_docs/26-catalog-and-usage-signal.md); on branch `sensitive_protection` (commit pending at the time of writing).
- Shipped with these deviations from the plan below (each decided against the real code, see the engineering doc): the catalog is a **`const` Dart seed** with a lazily built `Catalog.bundled` — no JSON asset, no data source, no repository, no DI line; entities are `Equatable`, not freezed; the consumer is `web_block_sync.dart` (the cubit never touched `AppDomainCatalog`); the Dart suffix walk is written fresh (the native adult walk deliberately includes the TLD); `Catalog` has its own 4-line `normalizeHost` (the catalog is a foundation `limits` depends on, so it cannot import `DomainValidator`); `EngineChannel.invokeOrThrow` exists because `_invoke` swallows every `PlatformException`; `UsageQuery`'s Context-free predicates are what the JVM test pins (only `junit` is available); native tests live under `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/`; the "baseline ≤ 8" check means `grep -c '^lib/'`; `docs/suggestion_docs/` does not exist in this repo, so the source links below are dead.
- Source: [A3 Category Catalog](../suggestion_docs/flutter-migration/A-foundations/A3-app-website-category-catalog.md) · [A1 Device Signal Layer](../suggestion_docs/flutter-migration/A-foundations/A1-device-signal-layer.md) · [D1 §7 native half](../suggestion_docs/flutter-migration/D-insights-engagement/D1-stats-insights.md)
- Feature areas: new `lib/features/catalog/`, new `lib/features/usage/`, native `engine/UsageQuery.kt`
- Effort: **M** (two self-contained additions, one asset, four new command methods)
- Blocks: M3, M4, M7 · Blocked by: nothing

Two foundations that everything downstream reads. Neither changes any existing behaviour: the
catalog is a new bundled asset with a lookup API, and the usage layer is a new pull-only query on
an already-granted permission.

---

## M0.1 — App / website category catalog

### Why now

Detoxo has **no notion of app categories**. `grep '"category"' assets/config/platforms_config.json`
returns nothing. The three category-ish things that exist are all something else:

| What | Where | Why it is not a category system |
|---|---|---|
| `ProtectedApp.category` | `lib/features/protected_apps/domain/` | An 11-value **privacy** enum (`banking`, `payments`, `password_manager`, …) used only as a display pill. Never groups, never blocks. |
| Web-blocker "categories" | `lib/features/limits/web_blocker/` | Two booleans: adult list on/off, app-derived domains on/off. |
| `AppDomainCatalog` | [`.../domain/entities/app_domain_catalog.dart`](../../lib/features/limits/web_blocker/domain/entities/app_domain_catalog.dart) | A package → domain map of 18 entries, already hand-grouped by `// Video / streaming`, `// Social`, `// Short-form video` **comments**. The taxonomy exists in prose and nowhere in code. |

Without categories there is no way to express "block distracting apps", to say what fraction of
screen time was distraction (M4), or to nudge on a class of app rather than a hand-picked list
(M7). This is the cheapest unlock in the plan.

### What the user gets

One-tap category selection wherever a package list is edited today, and honest wording in stats —
"3 h 12 m, 1 h 48 m of it distraction" rather than a raw total.

### Algorithm & control flow

Straight from A3, with its failure discipline preserved: **every load failure logs and degrades to
an empty catalog; nothing throws.** A missing or corrupt asset must never break app start.

```
load()                                    // once, lazily, cached forever
  json = rootBundle.loadString(_assetPath)
        ?? return Catalog.empty           // log + empty, never rethrow
  for each category in json.categories:
      parse {id, displayName, behavior, services[]}
      on parse error: log "Failed to parse category: <id>"; skip this one
  build 4 indices:
      packageToCategory, domainToCategory, packageToService, domainToService
  duplicate key → last writer wins; log when the collision changes the category

behaviorFrom(s) = "distracting" | "productive" | "neutral"
                  else: log "Unknown category behavior: <s>, defaulting to neutral"

normalizeHost(h) = h.toLowerCase().trim()
                    .removeSuffix(".")      // the source data has "glu.com." — a real bug
                    .removePrefix("www.")

suffixesOf(host):                           // stop BEFORE the TLD
  parts = host.split(".")
  for i in 0 .. parts.length - 2:           // never yields the bare TLD
      yield parts.sublist(i).join(".")
      // m.facebook.com → [m.facebook.com, facebook.com]  — never "com"

categoryForHost(h) = first suffixesOf(normalizeHost(h)) hit in domainToCategory
categoryForPackage(p) = packageToCategory[p]
behaviorForPackage(p) = categoryForPackage(p)?.behavior ?? neutral
```

The `suffixesOf` generator is the same shape `WebBlockEngine.matchHost` already walks for the
adult set. **Do not write a second one** — factor the Dart copy so the web blocker can adopt it
later, and leave the native copy alone (it is on the hot path and already correct).

`categoryForPackage` and `behaviorForPackage` are called per foreground change by M7 and per
stats recompute by M4. Both are `Map` lookups after the one-time build; the build is O(entries)
and happens once per process.

### Data model

**No drift.** One bundled asset plus an in-memory index; nothing persisted, because the catalog is
static data, not user state.

`assets/config/app_categories.json`:

```jsonc
{
  "version": 1,
  "categories": [
    {
      "id": "short_form_video",
      "displayName": "Short-form video",
      "behavior": "distracting",
      "services": [
        { "id": "instagram", "displayName": "Instagram",
          "androidPackages": ["com.instagram.android", "com.instagram.lite"],
          "domains": ["instagram.com"] }
      ]
    }
  ]
}
```

Dart entities (freezed, in `domain/entities/`):

| Type | Shape |
|---|---|
| `enum AppBehavior` | `distracting`, `productive`, `neutral` — `AppBehavior.fromJson` defaults to `neutral` |
| `CategoryService` | `{id, displayName, androidPackages = const [], domains = const []}` |
| `AppCategory` | `{id, displayName, behavior, services = const []}` |
| `Catalog` | value object: the 4 indices + `categoryForPackage` / `categoryForHost` / `behaviorForPackage` / `packagesIn(categoryId)`, plus `Catalog.empty` |

Seed content: the 18 entries already in `AppDomainCatalog`, plus the 27 packages in
`assets/config/platforms_config.json` (all `short_form_video` or `social`), plus `productive` and
`neutral` entries for the common launcher/messaging/tools packages so the default is not
"everything is neutral". Target **8–12 categories**, not A3's 21 — Detoxo does not need
`games` split from `puzzle_games`.

### Channel delta

**None.** The catalog is pure Dart. Native never sees the taxonomy — when a category is used as a
block target, M3 resolves it to a flat package list in Dart before pushing, exactly as
`AppBlockCubit` already resolves its list before `pushAppBlocklist`.

### Module layout

```
lib/features/catalog/
├── catalog.dart                              # barrel — the only public entry
├── domain/
│   ├── entities/{app_behavior,app_category,catalog}.dart
│   └── repositories/category_catalog_repository.dart   # Future<Catalog> load()
└── data/
    ├── datasources/catalog_asset_data_source.dart      # rootBundle, swallows + logs
    └── repositories/category_catalog_repository_impl.dart  # _cached ??= _build()
```

No `presentation/` — the catalog has no screens of its own; consumers render it.
Registered in [`lib/core/di/injector.dart`](../../lib/core/di/injector.dart) as
`..registerLazySingleton<CategoryCatalogRepository>(() => CategoryCatalogRepositoryImpl(sl()))`,
following the `ConfigRepository` line directly above it. The `AssetBundle` is injected the same
way `ConfigRepositoryImpl` takes it, so tests use a fake bundle and never touch `rootBundle`.

### Reuse map

| Existing | Imitate |
|---|---|
| `ConfigRepositoryImpl` | Injectable `AssetBundle` + memoised parse + lenient failure |
| `AppDomainCatalog` | The seed data and its grouping comments — then **delete it** and repoint `WebBlockCubit`'s "block sites for blocked apps" at `Catalog.domainsForPackage`, so there is one map and not two |
| `test/bundled_config_test.dart` | The asset-parses-and-has-expected-shape test pattern |

### Steps

1. Author `assets/config/app_categories.json`. `assets/config/` is already declared in
   `pubspec.yaml` — **no pubspec change.**
2. Add the four entities + `Catalog` under `lib/features/catalog/domain/`.
3. Add the asset data source and the memoising repository impl.
4. Add the barrel `lib/features/catalog/catalog.dart` exporting only `domain/entities` and the
   repository interface.
5. Register in `injector.dart`.
6. Repoint `WebBlockCubit`'s app-derived domains at the catalog; delete `app_domain_catalog.dart`.
7. Test `test/catalog_test.dart`: asset parses; `m.facebook.com` and `www.facebook.com` both
   resolve; a bare TLD (`com`) resolves to **null**; a trailing-dot host normalises; an unknown
   behavior string falls back to `neutral`; a malformed category is skipped without failing the
   load; a missing asset yields `Catalog.empty`.
8. `/docs-sync` — add a mapping row for `lib/features/catalog/**`.

---

## M0.2 — Usage signal layer

### Why now

`android.permission.PACKAGE_USAGE_STATS` is **declared in the manifest**,
`hasUsageAccess` / `openUsageAccessSettings` are **implemented** in `CommandHandler.kt`, and
Usage Access is **offered in the permission funnel** as `AppPermission.usageAccess` — and then:

```
$ grep -rn "UsageStats\|queryEvents\|queryUsageStats" android/app/src/main/kotlin/
$    # nothing
```

The data is never read. Every screen-time number in the app is instead inferred from gaps between
accessibility events, and the code says so itself at
[`engine/ContentCounter.kt:170`](../../android/app/src/main/kotlin/com/errorxperts/detoxo/engine/ContentCounter.kt#L170):

> `ponytail: active-event heuristic — undercounts truly passive, event-quiet playback. Upgrade
> path = a 1 Hz foreground ticker while a monitored app is front-most (mirroring the service's
> Conscious accountant).`

This milestone takes the **cheaper** of the two upgrade paths. A 1 Hz ticker burns battery to
recompute something the OS already tracks accurately; `UsageStatsManager` gives the same number
for the cost of one binder call on demand. Declaring a sensitive special-access permission and
never using it is also a weak position at Play review.

### What the user gets

Screen-time figures that match the phone's own Digital Wellbeing numbers instead of drifting below
them, and — via M3 — daily limits that can actually be enforced rather than only displayed.

### Algorithm & control flow

Pull-only. **No EventChannel, no polling, no ticker** — query on screen open and on refresh, per
D1's explicit guidance.

```
queryAppUsage(startMillis, endMillis):
    guard hasUsageAccess() else throw PlatformException("USAGE_ACCESS_DENIED")
    usm.queryAndAggregateUsageStats(start, end)
      .values
      .filter { it.totalTimeInForeground > 0 }        // drop the long tail of zeros
      .map { {package: it.packageName, foregroundMillis: it.totalTimeInForeground} }

queryUsageEvents(startMillis, endMillis):
    guard hasUsageAccess() else throw PlatformException("USAGE_ACCESS_DENIED")
    out = []
    it = usm.queryEvents(start, end)
    while (it.hasNextEvent()):
        e = UsageEvents.Event(); it.getNextEvent(e)
        if (e.eventType == 1 || e.eventType == 18):    // MOVE_TO_FOREGROUND | SCREEN_INTERACTIVE
            out += {package: e.packageName, type: e.eventType, timestampMillis: e.timeStamp}
    return out                                         // ascending, as the OS yields it
```

Only two event types are kept. `1` = `MOVE_TO_FOREGROUND` (app opens, drives context switches and
distraction opens); `18` = `SCREEN_INTERACTIVE` (device pickups, drives pickup count and
first/last pickup). Everything else is discarded at the native boundary so the payload stays small.

Both run on `CommandHandler`'s **existing `ioExecutor`** — the same off-platform-thread pattern
`installedPackages` and `installedApps` already use — and post the result back on the main looper.
A day of events is typically a few hundred entries; a week is a few thousand. Callers must batch
by day rather than requesting a month in one call.

**Access denied is a first-class result, not a crash.** Usage Access is optional in the funnel, so
callers must render a truthful *unknown* state — the pattern EVO-014 established for permission
and service states. Never render `0 m` for "we were not allowed to look".

### Data model

Nothing persisted at this layer. Dart entities only:

| Type | Shape |
|---|---|
| `AppUsage` | `{String package, int foregroundMillis}` |
| `UsageEvent` | `{String package, UsageEventType type, int timestampMillis}` |
| `enum UsageEventType` | `moveToForeground(1)`, `screenInteractive(18)` + `fromRaw(int)` |
| `sealed UsageQueryResult` | `granted(List<…>)` \| `denied()` \| `unavailable()` — so "unknown" survives to the UI |

M4 owns the day rollups that *do* persist; see [05](05-M4-insights.md).

### Channel delta

Two new commands on `com.errorxperts.detoxo/commands`. Full contract in
[09](09-contracts-and-storage.md).

| Method | Args | Returns |
|---|---|---|
| `queryAppUsage` | `{startMillis: Long, endMillis: Long}` | `List<{package: String, foregroundMillis: Long}>` |
| `queryUsageEvents` | `{startMillis: Long, endMillis: Long}` | `List<{package: String, type: Int, timestampMillis: Long}>` |

Both throw `PlatformException("USAGE_ACCESS_DENIED")` when the grant is missing, and
`PlatformException("BAD_ARGS")` on missing/invalid bounds — matching the existing arms rather
than silently returning an empty list, because an empty list is indistinguishable from "a quiet
day" and would print a confident wrong number.

No new event types. No new permission — `PACKAGE_USAGE_STATS` is already declared.

### Module layout

```
lib/features/usage/
├── usage.dart                                  # barrel
├── domain/
│   ├── entities/{app_usage,usage_event,usage_query_result}.dart
│   └── repositories/usage_repository.dart      # queryAppUsage / queryUsageEvents / hasAccess
└── data/repositories/usage_repository_impl.dart

android/.../engine/UsageQuery.kt                # object; pure UsageStatsManager wrapper
android/.../channels/CommandHandler.kt          # +2 arms, delegating to UsageQuery
```

`UsageQuery.kt` takes a `Context` and returns plain `List<Map<String, Any>>` — no Flutter types —
so it stays JVM-testable in `android/app/src/test/`, the way `ReelTracker.kt` and its 23-scenario
`ReelTrackerTest.kt` already are.

### Reuse map

| Existing | Imitate |
|---|---|
| `CommandHandler.installedApps` | `ioExecutor` off-thread work + main-looper result post |
| `CommandHandler.hasUsageAccess` | The `AppOpsManager.unsafeCheckOpNoThrow(OPSTR_GET_USAGE_STATS, …) == MODE_ALLOWED` check — call it, do not duplicate it |
| `engine/ReelTracker.kt` + `ReelTrackerTest.kt` | Android-free object + JVM unit test in the precommit gate (EVO-023) |
| `PermissionsCubit` tri-state reads | Never coerce unknown to denied |

### Steps

1. Add `android/.../engine/UsageQuery.kt` with `appUsage(start, end)` and `events(start, end)`.
2. Add the two `CommandHandler` arms, delegating on `ioExecutor`.
3. Add JVM tests in `android/app/src/test/` for the type filter (only 1 and 18 survive) and the
   `totalTimeInForeground > 0` filter.
4. Add the Dart entities, repository interface, and impl over `EngineChannel`.
5. Add the two method-name constants to
   [`lib/core/constants/channel_constants.dart`](../../lib/core/constants/channel_constants.dart),
   with doc comments matching the density of the existing ones.
6. Add the barrel; register the repository in `injector.dart`.
7. Test `test/usage_repository_test.dart` with a mocked channel: denied → `denied()`, not an empty
   list; bad args surface as an error; a normal response maps cleanly.
8. `/docs-sync` — update `18-platform-channel-contracts.md` and add a mapping row.

---

## Risks & ceilings

Leave these as `ponytail:` markers at the sites named:

- **`UsageQuery.kt`** — `ponytail: pull-only, no cache; a caller that queries per frame will hurt.
  Upgrade path = a day-keyed memo in the M4 rollup store.`
- **`CategoryCatalogRepositoryImpl`** — `ponytail: bundled static taxonomy; an app released after
  our last build is neutral until we ship a new asset. Upgrade path = the existing swap-in remote
  ConfigRepository seam, versioned by platformConfigVersion.`
- Usage Access remains **optional**. If M3's time limits later depend on it, that dependency must
  be stated in the funnel copy before it ships — not discovered by a user whose limit silently
  never fires.

## Validation

- [ ] `bash tool/dev.sh precommit` passes (format, analyze, test, boundaries, native JVM tests)
- [ ] `tool/boundaries_baseline.txt` line count ≤ 8
- [ ] `pubspec.yaml` unchanged
- [ ] Manifest unchanged (no new permission)
- [ ] Catalog: `Catalog.empty` on a deleted asset; app still starts
- [ ] Usage: with Usage Access **revoked**, both commands raise `USAGE_ACCESS_DENIED` and the Dart
      layer yields `denied()`; nothing renders `0 m`
- [ ] Device sanity: grant Usage Access, query today, compare against Settings → Digital
      Wellbeing. Totals should agree within a minute or two
- [ ] Invariants grep clean: Detoxo/errorxperts only; one channel pair; no drift import
- [ ] `/docs-sync` run

## Target files

**New** — `assets/config/app_categories.json` · `lib/features/catalog/**` · `lib/features/usage/**` ·
`android/.../engine/UsageQuery.kt` · `android/app/src/test/UsageQueryTest.kt` ·
`test/catalog_test.dart` · `test/usage_repository_test.dart`

**Edited** — `lib/core/constants/channel_constants.dart` · `lib/core/di/injector.dart` ·
`android/.../channels/CommandHandler.kt` · `lib/features/limits/web_blocker/presentation/web_block_cubit.dart`

**Deleted** — `lib/features/limits/web_blocker/domain/entities/app_domain_catalog.dart`
