# Detection Config Schema

Detoxo's blocking engine is **config-driven**. What surfaces get blocked, how, and
in which apps is not hard-coded — it is described by two JSON documents shipped as
assets and (by design) refreshable from a remote backend later:

| Asset | `AppConstants` key | Drives |
| --- | --- | --- |
| `assets/config/platforms_config.json` | `bundledPlatformsConfig` | The detection engine: apps -> surfaces -> view-id detectors -> block modes. |
| `assets/config/initial_config.json` | `bundledInitialConfig` | App-shell config: version gating, feature flags, ad slots, in-app notifications, premium CTA. |

Both are **offline-first**: the bundled copy is authoritative today. A remote
`ConfigRepository` is a documented swap-in — there is no live backend wired up, so
`responsecode: 200` / `message: "Success"` / `configVersion` fields in the JSON are
vestigial server-envelope fields, harmless when parsed from an asset.

> Naming note: the `detectionType` enum value `curious` / wire token `CURIOUS` (the
> earn-as-you-abstain plan) is **internal**; its user-facing label is **"Conscious"**.
> That token does not appear in these config files but shows up in the OVERLAY
> `params` as `curious_support`. `iconUrl`s now point at **bundled local assets**
> (`assets/images/social_icon_pack/<base>.png`); the JSON still carries legacy
> `notificationId`/`ctaUrl` strings referencing the old app — those are **infra
> follow-ups**, not new facts to invent.

---

## 1. `platforms_config.json` — the detection contract

### 1.1 Shape

```
{
  "responsecode": 200,
  "featuredApps": {
    "<appKey>": { AppDetails, "platforms": [ Platform, ... ] },
    ...
  },
  "message": "Success",
  "configVersion": 32
}
```

`featuredApps` is an **object keyed by app** (usually the Android package name, but
the key is not load-bearing — see the parser below). Each value is an *app* whose
`platforms` array lists the individual blockable *surfaces* within that app. Each
platform carries a `detectors` map of *view-id rules*. This three-level nesting —
**app -> platform -> detector** — is the whole schema.

```
featuredApps[appKey]                 AppDetails   (Instagram)
        └── platforms[]              Platform     (Instagram Reels, Stories, Feed…)
                └── detectors{}      Detector     (FINDBYID → :id/clips_author_username)
```

### 1.2 App level (`AppDetailsModel`)

Dart model: `lib/features/blocking/shared/data/models/platform_config_model.dart`.

| Field | Type / default | Meaning |
| --- | --- | --- |
| `packageName` | `String` (required) | Android package. The **only** app field the native parser reads. |
| `appName` | `String` `''` | Display name (e.g. `"Instagram"`). |
| `iconUrl` | `String` `''` | Icon: a bundled asset path (`assets/images/social_icon_pack/<base>.png`, one brand-colored icon per app), rendered by `AppIconAvatar`. Empty ⇒ letter-tile fallback. An `http…` value still loads remotely (for remote config). |
| `priority` | `int` `0` | UI ordering in the block list / dashboard. |
| `premiumExclusive` | `bool` `false` | Whole app is premium-gated in the UI. |
| `supportInAppYtShorts` | `bool` `false` | Marks in-app-browser YouTube-Shorts hosts (browsers, PW, Jio). |
| `minAppVersion` / `maxAppVersion` | `int` `-1` | Version gating (`-1` = unbounded). |
| `showInDashboard` | `bool` `false` | Surface the app on the dashboard. |
| `showIfNotInstalled` | `bool` `false` | List even when the app isn't installed. |
| `appOpenActions` | `[{name,url}]` | Deep-link shortcuts (e.g. YouTube "Subscriptions"). |
| `browser` | `bool` `false` | JSON-keyed to Dart `isBrowser`; marks a web browser (feeds web-block flow, not view-id detection). |
| `actionOnLaunch`, `paramsClass`, `params` | | App-level launch hooks, largely `NONE`/`-1`/`{}` in the bundle; **not consumed** by the native detector. |

### 1.3 Platform level (`PlatformModel`)

A *platform* is one blockable surface. This is the unit the user toggles on/off and
the unit the engine iterates.

| Field | Type / default | Meaning |
| --- | --- | --- |
| `platformId` | `String` (required) | Stable id, e.g. `ig_reel`, `yt_shorts`, `snap_stories`. Used for enable/disable persistence, counter exclusion, and `blocked` events. |
| `platformName` | `String` `''` | Display name. |
| `detectors` | `Map<String, DetectorModel>` | Detector **kind -> rule**; key is the detector kind (see §1.4). |
| `detectionType` | `String` `'LEGACY'` | Strategy: `LEGACY \| CALIBRATION \| OVERLAY \| MANUAL \| NONE`. Only `LEGACY`/`OVERLAY` are acted on (see §2.2). |
| `defaultStatus` | `bool` `true` | Default on/off before the user customizes it. |
| `customizable` | `bool` `true` | Whether the user may toggle it. |
| `showInDashboard` | `bool` `false` | Show on the dashboard. |
| `showAlwaysInBlockList` | `bool` `false` | Pin into the block list regardless of install state. |
| `premiumExclusive` | `bool` `false` | Premium-gated surface. |

### 1.4 Detector level (`DetectorModel`)

The `detectors` map is keyed by **detector kind**. In the bundled config the keys
seen are `FINDBYID`, `VIEWID_RES_NAME`, and `CONT_DESC`. The native `DetectorRule`
also names `BROWSER`. **Only `FINDBYID` and `VIEWID_RES_NAME` are acted on** by the
engine; `CONT_DESC` (content-description string matching, used by the Facebook Reels
legacy rule) is parsed but skipped at runtime.

| Field | Type / default | Meaning |
| --- | --- | --- |
| `identifiers` | `List<String>` | View-ids (or, for `CONT_DESC`, text strings) to match. Any hit fires. |
| `supportedBlockModes` | `List<String>` | Allowed block modes, e.g. `["PRESS_BACK","KILL_APP"]`. Constrains user choice. |
| `defaultBlockMode` | `String` `'PRESS_BACK'` | Fallback block mode for this detector. |
| `priority` | `int` `0` | Detectors within a platform are **sorted ascending by priority** natively before evaluation. |
| `childNodeLimit` | `int` `-1` | Advisory cap on tree depth for this detector (`-1` = none). |
| `haltOnDetect` | `bool` `true` | On a match, stop scanning further detectors/platforms this event. |
| `params` | `String` `''` | Escaped JSON payload; meaningful for `OVERLAY` (see §1.6). |
| `paramsClass` | `int` `0` | Selects how `params` is interpreted (`0` = none, `1` = overlay params). |
| `message`, `coupleWith`, `actionOnLaunch`, `detectionParams` | | Present in the wire format; not consumed by the current native detector. |

### 1.5 Real rows from the bundle

**YouTube Shorts** — the canonical single-detector `LEGACY` / `FINDBYID` surface.
The identifier is a bare `:id/...` suffix; the engine prefixes the package at match
time (§2.3):

```jsonc
"com.google.android.youtube": {
  "packageName": "com.google.android.youtube",
  "appName": "Youtube",
  "platforms": [{
    "platformId": "yt_shorts",
    "detectionType": "LEGACY",
    "detectors": {
      "FINDBYID": {
        "supportedBlockModes": ["PRESS_BACK", "KILL_APP"],
        "defaultBlockMode": "PRESS_BACK",
        "identifiers": [":id/reel_player_underlay"],
        "priority": 0, "haltOnDetect": true, "childNodeLimit": -1
      }
    },
    "defaultStatus": true, "showInDashboard": true
  }]
}
```

**Snapchat Stories** — one platform with **two** detector kinds. `FINDBYID` matches
`:id/view_profile`; `VIEWID_RES_NAME` matches fully-qualified names verbatim and caps
the DFS at `childNodeLimit: 500`:

```jsonc
"platformId": "snap_stories",
"detectionType": "LEGACY",
"detectors": {
  "FINDBYID":        { "identifiers": [":id/view_profile"], "childNodeLimit": -1, ... },
  "VIEWID_RES_NAME": {
    "identifiers": [
      "context_vertical_actions/context_vertical_action_share",
      "context_vertical_actions/context_vertical_action_favorite"
    ],
    "childNodeLimit": 500, ...
  }
}
```

**Reddit Watch** — a pure `VIEWID_RES_NAME` surface (the identifier is a plain
resource name with no `:id/` prefix and no package):

```jsonc
"platformId": "reddit_watch",
"detectionType": "LEGACY",
"detectors": { "VIEWID_RES_NAME": { "identifiers": ["content_video_view"], ... } }
```

**TikTok** — note `defaultBlockMode: "KILL_APP"` (app-level `actionOnLaunch:
"KILL_APP"` too) rather than the usual back-press:

```jsonc
"platformId": "tiktok_clips",
"detectors": { "FINDBYID": {
  "supportedBlockModes": ["PRESS_BACK","KILL_APP"],
  "defaultBlockMode": "KILL_APP",
  "identifiers": [":id/desc"], ...
}}
```

**"Allow Reels By Friends"** (`ig_reel_by_friend`) — a detector whose only supported
mode is `NONE`. It matches the DM reply bar (`:id/reply_bar_edittext`); a `NONE` block
mode means *detected but deliberately not blocked* (an allow-list exception). It is
`customizable: false`, `defaultStatus: false`.

**CALIBRATION / empty-detector surfaces** — many apps ship a platform with
`"detectors": {}` and `detectionType: "CALIBRATION"` (e.g. `insta_lite`,
`facebook_lite`, `com_google_android_youtube` in-app shorts, `opera_yt_reels`,
`jio_sphere_yt_reels`, `pw_yt_reels`). These are **placeholders** — no view-ids are
known yet, so the engine never acts on them (see §2.2). `bluesky` ships with
`"platforms": []` entirely.

### 1.6 OVERLAY params (Instagram Feed)

Exactly one bundled surface uses `detectionType: "OVERLAY"` with a populated
`params`: `ig_feed` (`paramsClass: 1`). Its `params` is an **escaped JSON string** —
a nested document parsed lazily by `OverlayParamsModel.tryParse`:

```jsonc
"platformId": "ig_feed",
"detectionType": "OVERLAY",
"detectors": { "FINDBYID": {
  "identifiers": [":id/media_group"],
  "paramsClass": 1,
  "params": "{ \"primary_id\": \":id/media_group\", \"config\": { \"curious_support\": true, \"block_all_support\": true, \"overlay_support\": false, \"blackout_message\": \"\" }, \"footer\": {...}, \"header\": {...}, \"primary_addons\": [\":id/carousel_media_group\"], \"secondary\": [...] }"
}}
```

The Dart models for this inner payload:

- `OverlayParamsModel` — `primary_id`, `config` (`OverlayConfigModel`), `primary_addons`.
- `OverlayConfigModel` — `curious_support` (Conscious mode eligible), `block_all_support`, `overlay_support`, `blackout_message`.

The `footer` / `header` / `secondary` keys exist in the JSON but are **not** modeled
in the current Dart `OverlayParamsModel`. `ig_feed` is `defaultStatus: false` and
`premiumExclusive: true`.

---

## 2. How the native side consumes it

Native parser: `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DetectionConfig.kt`.
Runtime consumer: `.../accessibility/DetoxoAccessibilityService.kt`.

Dart pushes the JSON string over the `pushConfig` MethodChannel command (fail-safe:
an absent or non-JSON-object payload is a no-op — never a config wipe); the service
calls `DetectionConfig.parse(json)` once per push and holds the result. The pushed
string persists in its own `detoxo_platforms_config` prefs file (see
[09-persistence-data-model.md](09-persistence-data-model.md) §2). Lookups on the
hot path are O(1) by package.

### 2.1 Parsing (`DetectionConfig.parse`)

The parser is deliberately lenient (`org.json`, `opt*` everywhere; any throw yields
`DetectionConfig.EMPTY`). It flattens the schema into **`Map<String, List<PlatformRule>>` keyed by package**:

- Iterate `featuredApps`; for each app take `packageName` (**falling back to the map key** if absent), skip apps with no `platforms` array.
- For each platform build a `PlatformRule` { `platformId`, `detectionType`, `premiumExclusive`, `defaultStatus`, `detectors` }.
- For each entry in `detectors`, the **map key becomes `viewDetector`** (`FINDBYID`, `VIEWID_RES_NAME`, …) and the value becomes a `DetectorRule` { `viewDetector`, `identifiers`, `supportedBlockModes`, `defaultBlockMode` (default `PRESS_BACK`), `priority` (default `0`), `haltOnDetect` (default `true`), `childNodeLimit` (default `-1`) }.
- `detectors.sortBy { it.priority }` — ascending priority ordering is applied at parse time.

Fields the native side **ignores** entirely: everything at the app level except
`packageName`/`platforms`, and detector `params`/`paramsClass`/`message`/`coupleWith`/
`actionOnLaunch`/`detectionParams`. (OVERLAY `params` is interpreted on the Dart side.)

```kotlin
data class DetectorRule(
    val viewDetector: String,        // FINDBYID | VIEWID_RES_NAME | CONT_DESC | BROWSER
    val identifiers: List<String>,
    val supportedBlockModes: List<String>,
    val defaultBlockMode: String,
    val priority: Int,
    val haltOnDetect: Boolean,
    val childNodeLimit: Int,
)
data class PlatformRule(
    val platformId: String,
    val detectionType: String,       // LEGACY | CALIBRATION | OVERLAY | MANUAL | NONE
    val premiumExclusive: Boolean,
    val defaultStatus: Boolean,
    val detectors: List<DetectorRule>,
)
```

### 2.2 Which `detectionType` / detector kinds are acted on

The blocking loop (`DetoxoAccessibilityService`) filters twice:

```kotlin
if (platform.detectionType != "LEGACY" && platform.detectionType != "OVERLAY") continue
...
if (detector.viewDetector != "FINDBYID" && detector.viewDetector != "VIEWID_RES_NAME") continue
```

So at runtime:

| detectionType | Acted on? |
| --- | --- |
| `LEGACY` | Yes |
| `OVERLAY` | Yes (view-id path; overlay UI beyond scope of this doc) |
| `CALIBRATION`, `MANUAL`, `NONE` | No (skipped — placeholders/UI-only) |

| detector kind | Acted on? |
| --- | --- |
| `FINDBYID` | Yes |
| `VIEWID_RES_NAME` | Yes |
| `CONT_DESC`, `BROWSER`, anything else | No (parsed, never evaluated) |

An enabled/disabled check follows: a platform runs if the user's enabled set contains
its `platformId`, or — if the user has never customized (empty set) — its
`defaultStatus`.

### 2.3 Detection: `FINDBYID` vs `VIEWID_RES_NAME`

Both kinds run the same 3-stage search (`matches()`); they differ **only** in how the
target id is built:

```kotlin
val byResName = detector.viewDetector == "VIEWID_RES_NAME"
val target = if (byResName) id else "$pkg$id"
```

- **`FINDBYID`** — identifiers are `:id/...` suffixes; the engine **prepends the package**, so `:id/reel_player_underlay` in `com.google.android.youtube` becomes `com.google.android.youtube:id/reel_player_underlay`.
- **`VIEWID_RES_NAME`** — identifiers are used **verbatim** (already fully-qualified resource names, e.g. `content_video_view`, `context_vertical_actions/...`).

The three stages, all gated on `isVisibleToUser`:

1. **Event source** — compare `event.source.viewIdResourceName` against each target.
2. **Direct lookup** — `root.findAccessibilityNodeInfosByViewId(target)`.
3. **Bounded DFS** — `ArrayDeque` walk over the window tree, capped at `MAX_NODES = 12000` nodes.

A single visible hit returns `true`. `haltOnDetect` (default `true`) then stops the
scan for that event.

### 2.4 Block-mode resolution

On a confirmed detection, `resolveBlockMode(detector)` picks the mode:

```kotlin
val def = store.defaultBlockMode                 // the user's global choice
if (def != "NONE" && (supported.isEmpty() || supported.contains(def))) return def
val firstSupported = supported.firstOrNull { it != "NONE" }
return firstSupported ?: detector.defaultBlockMode.ifBlank { "PRESS_BACK" }
```

The user's global default wins **if** the detector's `supportedBlockModes` allows it;
otherwise the first supported non-`NONE` mode; otherwise the detector's own
`defaultBlockMode`; final fallback `PRESS_BACK`. Execution:

| Mode | Effect |
| --- | --- |
| `PRESS_BACK` (default) | `performGlobalAction(GLOBAL_ACTION_BACK)`, rate-limited. |
| `KILL_APP` | Back + `ActivityManager.killBackgroundProcesses(pkg)`. |
| `LOCK_SCREEN` | Back + device-admin `lockNow()`. |
| `NONE` | No-op (allow-list exception, e.g. `ig_reel_by_friend`). |

### 2.5 Content counter reuses the same rules

The decoupled content counter (`isReelPlatform`) reuses `platformsFor` + `matches`,
but **excludes** feed/story/status surfaces via a hard-coded set so only true reel
surfaces are counted:

```kotlin
NON_REEL_PLATFORM_IDS = setOf(
  "ig_feed", "ig_stories", "insta_pro_stories", "insta_pro2_stories",
  "snap_stories", "wa_status", "wab_status",
)
```

Those `platformId`s therefore still **block** (if enabled) but do **not** increment
the reel/short counter.

---

## 3. `initial_config.json` — app-shell config

Model: `lib/features/blocking/shared/data/models/initial_config_model.dart`
(`InitialConfigModel`). This file does **not** feed the detection engine; it configures
the surrounding app. Top-level keys:

| Key | Model | Purpose |
| --- | --- | --- |
| `versionAvailability` | `VersionAvailabilityModel` (+ `VersionInfoModel`) | Update prompt / force-update gating (`versionCode`, `versionName`, `promptUpdate`, `forceUpdate`, `beta`, `changelog`). |
| `inappNotification` | `List<InAppNotificationModel>` | In-app cards (feedback, rating, community, roadmap). |
| `warningMessages` | `List<InAppNotificationModel>` | Blocking warnings (accessibility required, battery optimization). |
| `admobConfig` | `Map<String, AdSlotModel>` | Ad slot -> `{adTag, adType}`. **Modeled only** — no live AdMob init in Dart; the app ships Google **test** ad ids. |
| `activePlanDetails` | `ActivePlanDetailsModel` | Entitlement flags (`premiumFeatures`, `blockAds`, …). Premium is a local **dev-unlock**, not live billing. |
| `premiumPurchaseCTA` | `PromoCtaModel` | Upgrade CTA copy. |
| `featuresAvailability` | `Map<String, FeatureFlagModel>` | Feature flags (`smart_mode`, `feed_blocker`, `reels_by_friends`, …) with OS-version bounds and `premiumOnly`. |
| `platformConfigVersion` | `int` | Mirror of the platforms-config version for staleness checks. |
| `adsConfig`, `inhouseNativeAdConfig`, `videoConfig` | — | Present in the bundle; **not** modeled by `InitialConfigModel` (ignored on parse). |

Note `featuresAvailability.reels_by_friends.params` is `":id/reply_bar_edittext"` —
the same view-id used by the `ig_reel_by_friend` allow-list detector in §1.5, letting
that exception be feature-flagged independently.

**Rebranded (Aug 2026).** This bundle was inherited from a prior app and carried its
branding throughout — notification ids, a prior-vendor CTA PDF link, a community link,
dead `ctaUrl` package ids, a third-party app promo under `inhouseNativeAdConfig`, and
`admobConfig` ad units under a **foreign publisher account**
(`ca-app-pub-1071824559641088/…`). All are gone: ids are `/detoxo/…`, copy is Detoxo's,
`admobConfig` is `{}`, and the unmodelled ad/video keys were dropped.
`versionAvailability` now matches the real app version with `available: false` so no
phantom update prompt can fire.

---

## 4. Field cheat-sheet (detection path)

```
featuredApps{}                         # object keyed by app (usually package)
 └─ <app>
     packageName        ← only app field the native parser reads
     platforms[]
      └─ <platform>
          platformId          ← enable/disable key, counter exclusion, event id
          detectionType       ← LEGACY|OVERLAY acted on; others skipped
          defaultStatus       ← default toggle when user hasn't customized
          detectors{}         ← keyed by detector KIND
           └─ <FINDBYID | VIEWID_RES_NAME | CONT_DESC>
               identifiers[]        ← view-ids (FINDBYID = pkg-prefixed; RES_NAME = verbatim)
               supportedBlockModes  ← constrains resolveBlockMode
               defaultBlockMode     ← per-detector fallback
               priority             ← detectors sorted ascending natively
               haltOnDetect         ← stop scan on first match
               childNodeLimit       ← advisory DFS cap (matches() uses global MAX_NODES=12000)
               params/paramsClass   ← OVERLAY-only nested JSON (Dart-side)
```

---

## Source files

- `assets/config/platforms_config.json`
- `assets/config/initial_config.json`
- `lib/features/blocking/shared/data/models/platform_config_model.dart`
- `lib/features/blocking/shared/data/models/initial_config_model.dart`
- `lib/core/constants/app_constants.dart` (`bundledPlatformsConfig` / `bundledInitialConfig`)
- `android/app/src/main/kotlin/com/errorxperts/detoxo/engine/DetectionConfig.kt`
- `android/app/src/main/kotlin/com/errorxperts/detoxo/accessibility/DetoxoAccessibilityService.kt` (config consumption: `platformsFor`, `matches`, `resolveBlockMode`, `isReelPlatform`, `NON_REEL_PLATFORM_IDS`)
