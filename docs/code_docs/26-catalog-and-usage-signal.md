# Category Catalog & Usage Signal Layer

Written from shipped source. Two foundations that later milestones read (rules, insights, the
soft nudge); neither changes existing behaviour beyond one repoint in the web blocker. Plan doc:
[`plan_docs/01-M0-foundations.md`](../plan_docs/01-M0-foundations.md) (shipped).

---

## 1. Category catalog — `lib/features/catalog/`

Detoxo's first notion of **app / website categories**. Before this, `ProtectedApp.category` was a
privacy pill, the web blocker's "categories" were two booleans, and the app→domain map lived as an
18-entry `AppDomainCatalog` grouped only by comments.

### Shape

Domain only — no `data/`, no `presentation/`, no injector line. The barrel `catalog.dart` exports:

| Type | Role |
|---|---|
| `enum AppBehavior { distracting, productive, neutral }` | `(wire, label)`; `fromWire` → `neutral` for anything unknown (a seed typo must never promote an app to "distracting") |
| `CategoryService { id, displayName, androidPackages, domains }` | the unit that owns package ids and domains — "Instagram" is a service |
| `AppCategory { id, displayName, behavior, services }` | what a rule targets / stats roll up by |
| `AppCategorySeed.categories` | the shipped taxonomy as a `const` list (the `ProtectedAppCatalog` shape) |
| `Catalog` | the indices + lookups; `Catalog.empty`; **`Catalog.bundled`** = `Catalog.build(AppCategorySeed.categories)`, built lazily once per process |

`Catalog.build` fills five maps — package→category, domain→category, package→service,
domain→service, and package→domains via the owning service. Duplicate keys are last-writer-wins
with an `AppLogger.w` when the collision changes the category.

Lookups: `categoryForPackage`, `behaviorForPackage` (→ `neutral`), `serviceForPackage`,
`domainsForPackage` (the `AppDomainCatalog.domainsFor` replacement), `categoryForHost`,
`serviceForHost`, `packagesIn(categoryId)`, `packagesWithBehavior(behavior)`.

`packagesWithBehavior` is the one lookup that is **scanned, not indexed** — it walks the
categories and flattens the matching `packagesIn` lists. That is deliberate: unlike `packagesIn`
(called per rule per resolve) it runs once per config push. It has two consumers:

- the soft nudge's watch list ([30](30-soft-nudge.md) §6) — derived from the taxonomy so there is
  no nudge list to curate and none to drift;
- **M8's `lockScope: DISTRACTING`** ([31](31-locked-rules-and-unblock.md) §4), which widens a
  *locked* schedule to every distracting package (and their domains) at snapshot time, so the lock
  keeps holding as new apps are installed. Same frequency — once per `pushRules`, and only for a
  rule the user explicitly marked — so the scan cost is unchanged.

> `ponytail:` the seed is static, so an app released after the last build is `neutral` — the nudge
> misses it and DISTRACTING misses it too. Both widen today's coverage; neither future-proofs it.

Host matching: `normalizeHost` (lowercase, trim, strip a trailing `.` and a leading `www.`) then
`suffixesOf`, which yields `m.facebook.com`, `facebook.com` and **stops before the bare TLD**. This is
deliberately *not* the native adult-list walk in `WebBlockEngine.matchHost`, which includes the
TLD so a bare `porn` line blocks every `*.porn` host — two rules for two jobs.

### Seed

Ten categories: **distracting** `short_form_video`, `social`, `video_streaming`, `games`;
**neutral** `news`, `messaging`, `browsers`, `tools`; **productive** `productivity`, `education`.
Rules the test enforces: category ids unique, every category has a service, no package in two
categories, every real package in `platforms_config.json` is categorised (the
`com_google_android_youtube` sentinel is excluded — it fails `isValidPackageName`), and the 18
legacy package→domain pairs are preserved **exactly** (YouTube Music is its own service so
`com.google.android.apps.youtube.music` keeps `music.youtube.com` alone). Apps are classified by
what the **app** is, not the surface Detoxo detects in it (WhatsApp Status is a surface; WhatsApp
is messaging; Physics Wallah is education).

`ponytail:` the taxonomy is static — an app released after the last build is neutral until a new
seed ships; the upgrade path is the `ConfigRepository` remote-refresh seam.

### Consumer

`lib/features/limits/web_blocker/domain/web_block_sync.dart` derives "block sites for blocked apps"
from `Catalog.bundled.domainsForPackage(app.packageName)`. Because every seeded service carries its
domains, the derivation now covers more apps than the old 18 — blocking WhatsApp with the toggle on
also blocks `web.whatsapp.com`, which is the toggle's stated semantics. `AppDomainCatalog` is deleted.

### Tests

`test/catalog_test.dart` — seed integrity (above), host resolution (`m.` / `www.` / trailing dot,
bare TLD → null, `music.youtube.com` → the YT Music service), `suffixesOf`, `normalizeHost`,
`AppBehavior.fromWire` fallback, `Catalog.empty` lookups, last-writer-wins on a collision.

---

## 2. Usage signal layer — `lib/features/usage/` + `engine/UsageQuery.kt`

`PACKAGE_USAGE_STATS` was declared, granted through the funnel and read by nothing; every
screen-time number was inferred from accessibility-event gaps. This layer reads the OS's own
`UsageStatsManager` — **pull-only**: no ticker, no cache, no EventChannel; Dart callers query on
screen open / refresh and batch by day, and the block screen asks once per wall (EVO-027, its
first user-visible consumer — [25](25-block-screen.md) §5).

### Native — `engine/UsageQuery.kt`

An `object` with constants only in its initializer (the unit-test stub jar throws on any invoked
Android method). Pure, JVM-tested: `keepsEvent(type)` (only `1` MOVE_TO_FOREGROUND and `18`
SCREEN_INTERACTIVE survive), `keepsUsage(ms)` (`> 0`), `validBounds(start, end)` (`start ≥ 0`,
`end > start`), `usageRow` / `eventRow` (the wire row shapes), `startOfDay(nowMs, zone)` (local
midnight), `countOpens(events, pkg)` (foreground **transitions** into `pkg` — an app resuming its
own next activity is not a new open). Android shell, untested: `hasAccess(context)` (the one
AppOps check, which `CommandHandler` delegates to), `appUsage(context, start, end)` =
`queryAndAggregateUsageStats` filtered + mapped; `events(context, start, end)` = the `queryEvents`
loop; `opensToday(context, pkg, nowMs)` = today's `queryEvents` window fed to `countOpens` without
building rows.

`ponytail:` pull-only, no cache; a caller that queries per frame will hurt. The day-keyed memo
this points at now exists as the insights rollup store ([28](28-insights.md) §4), but it is the
caller's cache, not this layer's.

### Channel — the two arms that throw

`CommandHandler` handles `queryAppUsage` and `queryUsageEvents` in one arm: reads `startMillis` /
`endMillis` as `Number` (Flutter marshals small longs as `Integer`), answers
`result.error("BAD_ARGS", …)` on missing/inverted bounds and `result.error("USAGE_ACCESS_DENIED",
…)` when `hasUsageAccess()` (the existing AppOps check) is false, then runs the query on the
existing `ioExecutor` and posts back on the main looper (the `installedApps` pattern); a query
failure is `result.error("USAGE_QUERY_FAILED", …)`. These are the **only** `result.error` calls in
the native tree: an empty list would be indistinguishable from a quiet day and would let a screen
print a confident `0 m` (EVO-014).

### Dart

`EngineChannel.invokeOrThrow<T>` is the one invoke that lets a `PlatformException` propagate
(still `null` off-Android / without the native side); `queryAppUsage` / `queryUsageEvents` return
raw `List<Map>?` rows through it.

| Type | Shape |
|---|---|
| `AppUsage { package, foregroundMillis }` | + `foreground` Duration |
| `enum UsageEventType { moveToForeground(1), screenInteractive(18) }` | `fromRaw(int?)` → null (row dropped) for anything else |
| `UsageEvent { package, type, timestampMillis }` | `fromChannel` → null on an unknown type / empty package |
| `sealed UsageQueryResult<T>` | `UsageGranted(data)` \| `UsageDenied()` \| `UsageUnavailable()` — the `Result/Ok/Err` shape |
| `UsageRepository` | `hasAccess()` (tri-state `bool?`), `queryAppUsage(start, end)`, `queryUsageEvents(start, end)` |

`UsageRepositoryImpl` maps `USAGE_ACCESS_DENIED` → `UsageDenied`, `BAD_ARGS` → `ArgumentError`
(a caller bug, surfaced loudly), any other failure or `null` → `UsageUnavailable`; an inverted
window throws before the channel is touched. Registered in `injector.dart` after
`PermissionRepository`. Its Dart consumers are `rule_sync` (spent limits, [27](27-rules-engine.md))
and the insights rollups ([28](28-insights.md)), which own the day-keyed cache this layer
deliberately does not have. The dashboard hero still keeps `ContentCounterCubit.timeToday`; the
block screen's "opened N times today" line reads the layer natively, never through this
repository.

### Tests

- JVM `engine/UsageQueryTest.kt`: only 1 and 18 survive; zero foreground dropped; bounds matrix;
  row key names pinned; `startOfDay` in two zones; `countOpens` counts transitions only.
- Dart `test/usage_repository_test.dart`: denied → `UsageDenied` (never `[]`); null →
  `UsageUnavailable`; other failure → `UsageUnavailable`; happy paths map and drop unknown types;
  `BAD_ARGS` → `ArgumentError`; inverted window refused with `verifyNever` on the channel;
  `hasAccess` tri-state passthrough.

## Source files

- `lib/features/catalog/catalog.dart`
- `lib/features/catalog/domain/app_category_seed.dart`
- `lib/features/catalog/domain/entities/{app_behavior,app_category,catalog}.dart`
- `lib/features/limits/web_blocker/domain/web_block_sync.dart` (consumer)
- `lib/features/usage/usage.dart`
- `lib/features/usage/domain/entities/{app_usage,usage_event,usage_query_result}.dart`
- `lib/features/usage/domain/repositories/usage_repository.dart`
- `lib/features/usage/data/repositories/usage_repository_impl.dart`
- `lib/core/platform_channels/engine_channel.dart` (`invokeOrThrow`, `queryAppUsage`, `queryUsageEvents`)
- `lib/core/constants/channel_constants.dart`
- `lib/core/di/injector.dart`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/UsageQuery.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/channels/CommandHandler.kt`
- `android/app/src/test/kotlin/com/errorxperts/detoxo/engine/UsageQueryTest.kt`
- `test/catalog_test.dart`, `test/usage_repository_test.dart`
