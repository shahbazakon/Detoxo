package com.errorxperts.detoxo.engine

import org.json.JSONException
import org.json.JSONObject

/**
 * What the block counters hand to Dart: today / total / date as before, plus
 * yesterday's finished count (EVO-060) and today's per-package tally
 * (EVO-059). A data class rather than a wider Triple so the two block sites and
 * the `blockStats` arm read named fields.
 */
data class BlockStats(
    val today: Int,
    val total: Int,
    val date: String,
    val yesterday: Int,
    val byPackage: Map<String, Int>,
)

/**
 * The arithmetic behind the per-package block tally and the yesterday
 * reference, kept free of Android so `BlockTallyTest` pins it on the JVM:
 * JSON strings and day keys in, JSON strings and ints out. [ConfigStore] owns
 * the prefs and the rollover; this object owns nothing but the rules.
 *
 * The tally lives natively on purpose. A Dart-side one would only see blocks
 * while the Flutter engine is alive — the flaw of the block-event feed the
 * Activity tab used to draw — and the engine blocks all day with the UI dead.
 */
object BlockTally {

    /**
     * How many packages a day keeps. Blocks concentrate in a handful of apps;
     * past that the tail is noise, and an unbounded map is a prefs entry that
     * grows with every app the user ever reached for.
     */
    const val MAX_PACKAGES = 20

    /** `{pkg: count}` → map, positive counts only; anything unreadable is an empty day, never a throw. */
    fun parse(json: String?): Map<String, Int> {
        if (json.isNullOrEmpty()) return emptyMap()
        return try {
            val obj = JSONObject(json)
            val out = LinkedHashMap<String, Int>()
            for (key in obj.keys()) {
                val n = obj.optInt(key, 0)
                if (n > 0) out[key] = n
            }
            out
        } catch (_: JSONException) {
            emptyMap()
        }
    }

    fun encode(tally: Map<String, Int>): String = JSONObject(tally as Map<*, *>).toString()

    /**
     * One more block for [pkg]. A newcomer past [cap] evicts the smallest
     * entry (ties: the oldest), so the apps blocked all day are never the ones
     * that fall off — EVO-049's rule for the web blocker's host tally.
     */
    fun record(json: String?, pkg: String, cap: Int = MAX_PACKAGES): String {
        val tally = LinkedHashMap(parse(json))
        if (pkg !in tally && tally.size >= cap) {
            tally.minByOrNull { it.value }?.let { tally.remove(it.key) }
        }
        tally[pkg] = (tally[pkg] ?: 0) + 1
        return encode(tally)
    }

    /**
     * The tally without [packages] — a newly protected app must leave today's
     * tally, not only tomorrow's (`docs/code_docs/24-protected-apps.md`).
     * Null when nothing was named, so the caller can skip the prefs write.
     */
    fun without(json: String?, packages: Set<String>): String? {
        if (json.isNullOrEmpty() || packages.isEmpty()) return null
        val tally = parse(json)
        val kept = tally.filterKeys { it !in packages }
        return if (kept.size == tally.size) null else encode(kept)
    }

    /**
     * Yesterday's count from what the store holds: one (date, count) for the
     * last recorded day and one rotated (date, count) written when the day
     * changed. Read-time rollover, like today's count:
     * - the stored day is today → the rotated pair, if it names yesterday;
     * - the stored day is yesterday (no block yet today) → its own count;
     * - anything older → 0, because a day with no record had no blocks.
     */
    fun yesterday(
        storedDate: String,
        storedToday: Int,
        rotatedDate: String,
        rotatedCount: Int,
        todayKey: String,
        yesterdayKey: String,
    ): Int = when (storedDate) {
        todayKey -> if (rotatedDate == yesterdayKey) rotatedCount else 0
        yesterdayKey -> storedToday
        else -> 0
    }
}
