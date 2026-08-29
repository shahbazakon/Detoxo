package com.errorxperts.detoxo.engine

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * Persistence for the short-video / reel awareness counter.
 *
 * Shares the same `detoxo_engine_prefs` SharedPreferences file as [ConfigStore]
 * so the AccessibilityService, [com.errorxperts.detoxo.channels.CommandHandler]
 * and the home-screen widget all read one source of truth. SRP: storage only —
 * the decision of WHEN to count lives in [ContentCounter].
 *
 * Counts are kept two ways: a per-day "today" bucket (reset on date rollover)
 * and an all-time "total". Each is split per package (JSON `{pkg: count}`),
 * mirroring [ConfigStore.recordBlock]/[ConfigStore.blockStats].
 */
class ContentCounterStore(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // The two flags are read on every accessibility event (the service gates
    // the whole counting pass on `enabled`); cache them per instance so the
    // hot path never takes the prefs lock. Every writer goes through the live
    // service's instance too (CommandHandler calls ContentCounter.setEnabled /
    // setBubbleEnabled after its own write), so the cache can't go stale.
    private var enabledCache: Boolean? = null
    private var bubbleCache: Boolean? = null

    /** Master on/off for the counter feature. Defaults on (awareness by default). */
    var enabled: Boolean
        get() = enabledCache ?: prefs.getBoolean(KEY_ENABLED, true).also { enabledCache = it }
        set(value) {
            enabledCache = value
            prefs.edit().putBoolean(KEY_ENABLED, value).apply()
        }

    /** Whether the floating bubble overlay may be shown (gated separately). */
    var bubbleEnabled: Boolean
        get() = bubbleCache ?: prefs.getBoolean(KEY_BUBBLE, true).also { bubbleCache = it }
        set(value) {
            bubbleCache = value
            prefs.edit().putBoolean(KEY_BUBBLE, value).apply()
        }

    /** Last bubble X position in px (−1 = unset → snaps to the default edge). */
    var bubbleX: Int
        get() = prefs.getInt(KEY_BUBBLE_X, -1)
        set(value) = prefs.edit().putInt(KEY_BUBBLE_X, value).apply()

    /** Last bubble Y position in px (−1 = unset → default offset from top). */
    var bubbleY: Int
        get() = prefs.getInt(KEY_BUBBLE_Y, -1)
        set(value) = prefs.edit().putInt(KEY_BUBBLE_Y, value).apply()

    /**
     * Bubble appearance as a JSON string (see Dart `BubbleStyle.toWire`). Empty =
     * unset → the native renderer falls back to its defaults. Pushed from Dart via
     * the `setCounterStyle` command.
     */
    var bubbleStyleJson: String
        get() = prefs.getString(KEY_BUBBLE_STYLE, "") ?: ""
        set(value) = prefs.edit().putString(KEY_BUBBLE_STYLE, value).apply()

    /** Home-widget appearance as a JSON string (see Dart `WidgetStyle.toWire`). */
    var widgetStyleJson: String
        get() = prefs.getString(KEY_WIDGET_STYLE, "") ?: ""
        set(value) = prefs.edit().putString(KEY_WIDGET_STYLE, value).apply()

    /**
     * Records one counted reel for [pkg] plus any accumulated-but-unwritten
     * usage time ([usageDeltaMs]) in ONE edit, and returns the resulting
     * snapshot built from the maps it already parsed — a count used to cost
     * three prefs writes and four JSON parses (usage flush + count + snapshot).
     *
     * Resets the today buckets first when the stored day differs from [dateKey]
     * (midnight rollover). Shared-rollover invariant: `cc_date` gates BOTH the
     * counts and the usage time, so whichever writer turns the day over must
     * also zero the OTHER feature's today bucket — mirrored in [recordUsage].
     */
    fun recordCount(pkg: String, dateKey: String, usageDeltaMs: Long = 0L): Map<String, Any?> {
        val rollover = prefs.getString(KEY_DATE, "") != dateKey

        val today = (if (rollover) 0 else prefs.getInt(KEY_TODAY, 0)) + 1
        val total = prefs.getInt(KEY_TOTAL, 0) + 1
        val perAppToday = if (rollover) JSONObject() else readMap(KEY_PER_APP_TODAY)
        val perAppTotal = readMap(KEY_PER_APP_TOTAL)
        perAppToday.put(pkg, perAppToday.optInt(pkg, 0) + 1)
        perAppTotal.put(pkg, perAppTotal.optInt(pkg, 0) + 1)
        val delta = usageDeltaMs.coerceAtLeast(0L)
        val timeToday = (if (rollover) 0L else prefs.getLong(KEY_TIME_TODAY, 0L)) + delta
        val timeTotal = prefs.getLong(KEY_TIME_TOTAL, 0L) + delta

        prefs.edit()
            .putString(KEY_DATE, dateKey)
            .putInt(KEY_TODAY, today)
            .putInt(KEY_TOTAL, total)
            .putString(KEY_PER_APP_TODAY, perAppToday.toString())
            .putString(KEY_PER_APP_TOTAL, perAppTotal.toString())
            .putLong(KEY_TIME_TODAY, timeToday)
            .putLong(KEY_TIME_TOTAL, timeTotal)
            .apply()
        return snapshotOf(dateKey, today, total, perAppToday, perAppTotal, timeToday, timeTotal)
    }

    /**
     * Adds [deltaMs] of foreground time spent in a monitored social app to
     * today's + all-time usage totals. Shares the [KEY_DATE] rollover with
     * [recordCount] (see the invariant there): on a new day this zeroes the
     * count today buckets too.
     */
    fun recordUsage(deltaMs: Long, dateKey: String) {
        if (deltaMs <= 0L) return
        val storedDate = prefs.getString(KEY_DATE, "")
        val rollover = storedDate != dateKey
        val timeToday = if (rollover) 0L else prefs.getLong(KEY_TIME_TODAY, 0L)

        val editor = prefs.edit()
            .putString(KEY_DATE, dateKey)
            .putLong(KEY_TIME_TODAY, timeToday + deltaMs)
            .putLong(KEY_TIME_TOTAL, prefs.getLong(KEY_TIME_TOTAL, 0L) + deltaMs)
        if (rollover) {
            editor.putInt(KEY_TODAY, 0).putString(KEY_PER_APP_TODAY, "{}")
        }
        editor.apply()
    }

    /**
     * Current counter snapshot for [dateKey]. Applies a read-time rollover (when
     * the stored day is stale the today values read as 0 WITHOUT writing — the
     * next [recordCount] performs the durable reset), so a snapshot pulled just
     * after midnight is correct even before the day's first reel.
     */
    fun snapshot(dateKey: String): Map<String, Any?> {
        val storedDate = prefs.getString(KEY_DATE, "") ?: ""
        val fresh = storedDate == dateKey
        return snapshotOf(
            dateKey = dateKey,
            today = if (fresh) prefs.getInt(KEY_TODAY, 0) else 0,
            total = prefs.getInt(KEY_TOTAL, 0),
            perAppToday = if (fresh) readMap(KEY_PER_APP_TODAY) else JSONObject(),
            perAppTotal = readMap(KEY_PER_APP_TOTAL),
            timeToday = if (fresh) prefs.getLong(KEY_TIME_TODAY, 0L) else 0L,
            timeTotal = prefs.getLong(KEY_TIME_TOTAL, 0L),
        )
    }

    private fun snapshotOf(
        dateKey: String,
        today: Int,
        total: Int,
        perAppToday: JSONObject,
        perAppTotal: JSONObject,
        timeToday: Long,
        timeTotal: Long,
    ): Map<String, Any?> = mapOf(
        "enabled" to enabled,
        "bubbleEnabled" to bubbleEnabled,
        "today" to today,
        "total" to total,
        "date" to dateKey,
        "perAppToday" to perAppToday.toIntMap(),
        "perAppTotal" to perAppTotal.toIntMap(),
        // Whole-app foreground time (ms) in monitored social apps, today +
        // all-time. Drives the dashboard screen-time ring and the bubble
        // tap-to-reveal. Shares the same fresh/rollover gate as the counts.
        "timeTodayMs" to timeToday,
        "timeTotalMs" to timeTotal,
        // Persisted appearance (JSON strings); the Dart cubit hydrates from these.
        "bubbleStyle" to bubbleStyleJson,
        "widgetStyle" to widgetStyleJson,
    )

    /** Today's running total for [dateKey] (0 after a rollover). Cheap path for the bubble. */
    fun todayCount(dateKey: String): Int =
        if (prefs.getString(KEY_DATE, "") == dateKey) prefs.getInt(KEY_TODAY, 0) else 0

    /** Today's accumulated foreground time in ms for [dateKey] (0 after a rollover). */
    fun timeTodayMs(dateKey: String): Long =
        if (prefs.getString(KEY_DATE, "") == dateKey) prefs.getLong(KEY_TIME_TODAY, 0L) else 0L

    private fun readMap(key: String): JSONObject =
        try {
            JSONObject(prefs.getString(key, "{}") ?: "{}")
        } catch (_: Throwable) {
            JSONObject()
        }

    private fun JSONObject.toIntMap(): Map<String, Int> {
        val out = HashMap<String, Int>(length())
        val it = keys()
        while (it.hasNext()) {
            val k = it.next()
            out[k] = optInt(k, 0)
        }
        return out
    }

    companion object {
        private const val PREFS = "detoxo_engine_prefs"
        private const val KEY_ENABLED = "cc_enabled"
        private const val KEY_BUBBLE = "cc_bubble_enabled"
        private const val KEY_BUBBLE_X = "cc_bubble_x"
        private const val KEY_BUBBLE_Y = "cc_bubble_y"
        private const val KEY_DATE = "cc_date"
        private const val KEY_TODAY = "cc_today"
        private const val KEY_TOTAL = "cc_total"
        private const val KEY_TIME_TODAY = "cc_time_today"
        private const val KEY_TIME_TOTAL = "cc_time_total"
        private const val KEY_PER_APP_TODAY = "cc_per_app_today"
        private const val KEY_PER_APP_TOTAL = "cc_per_app_total"
        private const val KEY_BUBBLE_STYLE = "cc_bubble_style"
        private const val KEY_WIDGET_STYLE = "cc_widget_style"
    }
}
