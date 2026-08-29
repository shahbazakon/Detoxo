package com.errorxperts.detoxo.engine

import org.json.JSONObject

/** A single view-id detector parsed from the platforms config. */
data class DetectorRule(
    val viewDetector: String,        // FINDBYID | VIEWID_RES_NAME | CONT_DESC | BROWSER
    val identifiers: List<String>,
    val supportedBlockModes: List<String>,
    val defaultBlockMode: String,
    val priority: Int,
    val haltOnDetect: Boolean,
    val childNodeLimit: Int,
    /**
     * The fully-qualified `viewIdResourceName`s the service compares against:
     * FINDBYID ids prefixed with the platform's package at parse time (a
     * VIEWID_RES_NAME id is already qualified). Built once here instead of on
     * every `matches()` call on the hot path.
     */
    val qualifiedIds: List<String>,
)

/** A blockable surface within an app (e.g. Instagram Reels). */
data class PlatformRule(
    val platformId: String,
    val detectionType: String,       // LEGACY | CALIBRATION | OVERLAY | MANUAL | NONE
    val premiumExclusive: Boolean,
    val defaultStatus: Boolean,
    val detectors: List<DetectorRule>,
    /**
     * Fully-qualified `viewIdResourceName` of the reel pager (EVO-024), or
     * null when the platform doesn't declare one. When set, the awareness
     * counter accepts page indices only from scroll events whose source is
     * this view — a one-or-two-item inner list can no longer pass as a page.
     * Filled per app from device calibration (`pagerViewId` in the config).
     */
    val pagerViewId: String?,
)

/**
 * Parsed, package-indexed view of `platforms_config.json`, built once whenever
 * Dart pushes a new config. Lookups during the hot path are O(1) by package.
 */
class DetectionConfig private constructor(
    private val byPackage: Map<String, List<PlatformRule>>,
) {
    fun platformsFor(pkg: String): List<PlatformRule> = byPackage[pkg] ?: emptyList()

    companion object {
        val EMPTY = DetectionConfig(emptyMap())

        fun parse(json: String?): DetectionConfig {
            if (json.isNullOrBlank()) return EMPTY
            return try {
                val root = JSONObject(json)
                val apps = root.optJSONObject("featuredApps") ?: return EMPTY
                val map = HashMap<String, MutableList<PlatformRule>>()
                val appKeys = apps.keys()
                while (appKeys.hasNext()) {
                    val appKey = appKeys.next()
                    val app = apps.optJSONObject(appKey) ?: continue
                    val pkg = app.optString("packageName", appKey)
                    val platforms = app.optJSONArray("platforms") ?: continue
                    val rules = map.getOrPut(pkg) { mutableListOf() }
                    for (i in 0 until platforms.length()) {
                        val p = platforms.optJSONObject(i) ?: continue
                        rules.add(parsePlatform(p, pkg))
                    }
                }
                DetectionConfig(map)
            } catch (t: Throwable) {
                EMPTY
            }
        }

        private fun parsePlatform(p: JSONObject, pkg: String): PlatformRule {
            val detectorsJson = p.optJSONObject("detectors")
            val detectors = mutableListOf<DetectorRule>()
            if (detectorsJson != null) {
                val keys = detectorsJson.keys()
                while (keys.hasNext()) {
                    val viewDetector = keys.next()
                    val d = detectorsJson.optJSONObject(viewDetector) ?: continue
                    val identifiers = d.optJSONArray("identifiers").toStringList()
                    detectors.add(
                        DetectorRule(
                            viewDetector = viewDetector,
                            identifiers = identifiers,
                            supportedBlockModes = d.optJSONArray("supportedBlockModes").toStringList(),
                            defaultBlockMode = d.optString("defaultBlockMode", "PRESS_BACK"),
                            priority = d.optInt("priority", 0),
                            haltOnDetect = d.optBoolean("haltOnDetect", true),
                            childNodeLimit = d.optInt("childNodeLimit", -1),
                            qualifiedIds = if (viewDetector == "VIEWID_RES_NAME") {
                                identifiers
                            } else {
                                identifiers.map { "$pkg$it" }
                            },
                        ),
                    )
                }
            }
            detectors.sortBy { it.priority }
            // Same qualification rule as FINDBYID ids: ":id/x" → "<pkg>:id/x";
            // a value that already carries its package is used verbatim.
            val pager = p.optString("pagerViewId").takeIf { it.isNotBlank() }?.let {
                if (it.startsWith(":")) "$pkg$it" else it
            }
            return PlatformRule(
                platformId = p.optString("platformId"),
                detectionType = p.optString("detectionType", "LEGACY"),
                premiumExclusive = p.optBoolean("premiumExclusive", false),
                defaultStatus = p.optBoolean("defaultStatus", true),
                detectors = detectors,
                pagerViewId = pager,
            )
        }

        private fun org.json.JSONArray?.toStringList(): List<String> {
            if (this == null) return emptyList()
            val out = ArrayList<String>(length())
            for (i in 0 until length()) out.add(optString(i))
            return out
        }
    }
}
