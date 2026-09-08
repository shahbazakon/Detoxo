package com.errorxperts.detoxo.engine

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.Process
import java.util.Calendar
import java.util.TimeZone

/**
 * Pull-only reads of [UsageStatsManager] — the OS's own per-app foreground
 * clock, which the accessibility-event heuristic in [ContentCounter] can only
 * approximate. No ticker, no cache, no EventChannel: Dart queries on screen
 * open / refresh and batches by day; the block screen asks once per wall
 * (EVO-027).
 *
 * The predicates and row shapers are pure so `UsageQueryTest` pins them on the
 * JVM; only [appUsage] / [events] / [opensToday] / [hasAccess] touch Android.
 * Nothing Android runs in this object's initializer (the unit-test stub jar
 * throws on any invoked method).
 *
 * ponytail: pull-only, no cache; a caller that queries per frame will hurt.
 * Upgrade path = a day-keyed memo in the M4 rollup store.
 */
object UsageQuery {

    /** `UsageEvents.Event.MOVE_TO_FOREGROUND` — an app came to the front. */
    const val EVENT_MOVE_TO_FOREGROUND = 1

    /** `UsageEvents.Event.SCREEN_INTERACTIVE` — a device pickup. */
    const val EVENT_SCREEN_INTERACTIVE = 18

    /** Only the two event types the insights need survive the boundary. */
    fun keepsEvent(type: Int): Boolean =
        type == EVENT_MOVE_TO_FOREGROUND || type == EVENT_SCREEN_INTERACTIVE

    /** Drops the long tail of installed-but-unused packages. */
    fun keepsUsage(foregroundMs: Long): Boolean = foregroundMs > 0L

    /** Bounds are epoch millis; an empty or inverted window is a caller bug. */
    fun validBounds(startMs: Long, endMs: Long): Boolean = startMs >= 0L && endMs > startMs

    fun usageRow(pkg: String, foregroundMs: Long): Map<String, Any> =
        mapOf("package" to pkg, "foregroundMillis" to foregroundMs)

    fun eventRow(pkg: String, type: Int, timestampMs: Long): Map<String, Any> =
        mapOf("package" to pkg, "type" to type, "timestampMillis" to timestampMs)

    /** Local midnight for [nowMs] in [zone] — the "today" every opens count starts from. */
    internal fun startOfDay(nowMs: Long, zone: TimeZone = TimeZone.getDefault()): Long =
        Calendar.getInstance(zone).apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

    /**
     * Foreground *transitions* into [pkg] over [events] = (package, type) in
     * time order. An app resuming its own next activity also reports
     * MOVE_TO_FOREGROUND, so a run of events for the same package is one open.
     */
    internal fun countOpens(events: Sequence<Pair<String, Int>>, pkg: String): Int {
        var opens = 0
        var last: String? = null
        for ((p, type) in events) {
            if (type != EVENT_MOVE_TO_FOREGROUND) continue
            if (p == pkg && last != pkg) opens++
            last = p
        }
        return opens
    }

    /**
     * [countOpens] for every package at once, under the same transition rule —
     * the map the limit reconciler measures open budgets against.
     */
    internal fun countOpensByPackage(events: Sequence<Pair<String, Int>>): Map<String, Int> {
        val opens = HashMap<String, Int>()
        var last: String? = null
        for ((p, type) in events) {
            if (type != EVENT_MOVE_TO_FOREGROUND) continue
            if (p != last) opens[p] = (opens[p] ?: 0) + 1
            last = p
        }
        return opens
    }

    /** The AppOps grant behind `PACKAGE_USAGE_STATS` — the one grant this object needs. */
    fun hasAccess(context: Context): Boolean = try {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
            )
        }
        mode == AppOpsManager.MODE_ALLOWED
    } catch (_: Throwable) {
        false
    }

    /** `List<{package, foregroundMillis}>`, `foregroundMillis > 0` only. */
    fun appUsage(context: Context, startMs: Long, endMs: Long): List<Map<String, Any>> =
        usageStats(context).queryAndAggregateUsageStats(startMs, endMs).values
            .filter { keepsUsage(it.totalTimeInForeground) }
            .map { usageRow(it.packageName, it.totalTimeInForeground) }

    /** `List<{package, type, timestampMillis}>`, ascending as the OS yields it. */
    fun events(context: Context, startMs: Long, endMs: Long): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val iterator = usageStats(context).queryEvents(startMs, endMs)
        val event = UsageEvents.Event()
        while (iterator.hasNextEvent()) {
            iterator.getNextEvent(event)
            if (!keepsEvent(event.eventType)) continue
            val pkg = event.packageName ?: continue
            out += eventRow(pkg, event.eventType, event.timeStamp)
        }
        return out
    }

    /**
     * How many times [pkg] came to the front since local midnight (EVO-027).
     * One binder call plus a linear scan of today's events — IO thread only.
     */
    fun opensToday(context: Context, pkg: String, nowMs: Long = System.currentTimeMillis()): Int {
        val iterator = usageStats(context).queryEvents(startOfDay(nowMs), nowMs)
        val event = UsageEvents.Event()
        val events = sequence {
            while (iterator.hasNextEvent()) {
                iterator.getNextEvent(event)
                val p = event.packageName ?: continue
                yield(p to event.eventType)
            }
        }
        return countOpens(events, pkg)
    }

    /**
     * Foreground milliseconds for [pkg] since local midnight (EVO-034).
     *
     * The wall pairs this with [opensToday]: "opened 7 times today" says how
     * often the reach happened, this says what it cost. One binder call, IO
     * thread only. `0` when the OS has no record for [pkg] today.
     */
    fun timeTodayMs(context: Context, pkg: String, nowMs: Long = System.currentTimeMillis()): Long =
        usageStats(context)
            .queryAndAggregateUsageStats(startOfDay(nowMs), nowMs)[pkg]
            ?.totalTimeInForeground
            ?.coerceAtLeast(0L)
            ?: 0L

    /** "1h 10m" / "12m" — the wall's spoken form, mirroring Dart `formatHm`. */
    internal fun formatHm(ms: Long): String {
        val totalMinutes = (ms / 60000L).coerceAtLeast(0L)
        val h = totalMinutes / 60L
        val m = totalMinutes % 60L
        return when {
            h == 0L -> "${m}m"
            m == 0L -> "${h}h"
            else -> "${h}h ${m}m"
        }
    }

    private fun usageStats(context: Context): UsageStatsManager =
        context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
}
