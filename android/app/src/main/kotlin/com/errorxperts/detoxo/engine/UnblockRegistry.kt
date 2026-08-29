package com.errorxperts.detoxo.engine

import org.json.JSONArray

/**
 * Per-target temporary unblocks (M8): "let me into Instagram for 15 minutes,
 * leave everything else protected". Dart pushes the active grants over
 * `pushTemporaryUnblocks`; native holds them in memory and enforces expiry
 * itself, so a grant lapses on time even if the Flutter app is never reopened.
 *
 * This generalises the per-site pause the web blocker shipped in EVO-012 —
 * [WebBlockEngine] no longer carries its own `pausedUntil`; it asks here.
 *
 * Android-free (like [RuleEngine] / [ReelTracker]) so the decision logic runs on
 * the JVM: both clocks are ARGUMENTS. [WebBlockEngine] takes a `Context` for its
 * bundled asset and is therefore untestable; this class must not follow it.
 *
 * ## Two things that are load-bearing
 *
 * **Deadlines are monotonic (EVO-048).** `endMs` rides the wire as a wall stamp
 * because that is the only thing that survives a reboot, and is converted ONCE
 * per parse to a [android.os.SystemClock.elapsedRealtime] deadline. Comparing
 * the wall clock per event would let a user roll the device clock back in
 * Settings and hold a grant open forever — a two-tap bypass with no PIN, and
 * exactly the hole EVO-048 closed for the pause this replaces.
 *
 * **The strict arm never consults this registry.** A grant lifts the App
 * Blocker, the plan and non-strict rules; a rule the user marked Strict (or
 * Locked, which implies it) is checked ABOVE the pause gate and never reads a
 * grant at all. That absence is the guarantee — no wire flag says "this grant is
 * privileged", so no Dart bug can mint one.
 *
 * ponytail: linear scan per event; fine at [MAX_GRANTS] = 50, and Dart prunes to
 * the same cap on write.
 */
class UnblockRegistry {

    /** One active grant. [untilElapsed] is a monotonic deadline, never a wall stamp. */
    private class Grant(val type: String, val id: String, val untilElapsed: Long)

    /**
     * Parsed grants plus the gates derived from them, swapped as ONE reference —
     * separate fields could be read half-updated by a concurrent event.
     * [source] is the string it was parsed from, so a re-push of an unchanged
     * payload costs no parse (the common resume case).
     */
    private class Snap(val grants: List<Grant>, val source: String?) {
        /**
         * The furthest deadline held for each type, so [hasAny] can expire
         * itself against the clock instead of standing true for the life of the
         * process. Booleans here meant that once a user took a single grant,
         * every later event paid a clock read and a scan of all 50 rows even
         * after the last one lapsed — and the case that matters most is exactly
         * the one Dart cannot fix, a grant expiring while Flutter is dead.
         * `0` = none.
         */
        val lastApp = latest(TYPE_APP)
        val lastReel = latest(TYPE_REEL)
        val lastWebsite = latest(TYPE_WEBSITE)

        private fun latest(type: String): Long {
            var out = 0L
            for (g in grants) {
                if (g.type == type && g.untilElapsed > out) out = g.untilElapsed
            }
            return out
        }
    }

    @Volatile private var snap = Snap(emptyList(), null)

    /**
     * Replace the active grants from the pushed JSON `[{targetType,targetId,endMs}]`.
     * Blank clears; a malformed payload keeps the previous set (the
     * [RuleEngine.setSnapshot] contract — never let a bad push unlock a phone,
     * and never let one lock it either).
     *
     * [nowWall] / [nowElapsed] are read once by the caller and passed in so this
     * class stays Android-free. A row whose deadline has already passed is
     * dropped here, which is the entire pruning story: stale grants can neither
     * accumulate in prefs nor come back after a clock jump, with no Dart push.
     */
    fun setGrants(json: String?, nowWall: Long, nowElapsed: Long) {
        if (json == snap.source) return
        val parsed = parse(json, nowWall, nowElapsed) ?: return
        snap = Snap(parsed, json)
    }

    /**
     * Whether [id] of [type] is currently unblocked. [nowElapsed] is
     * `elapsedRealtime`, matching the deadlines stored at parse.
     *
     * `APP` and `REEL` match exactly (a package name, a `platformId`).
     * `WEBSITE` also matches a subdomain of the granted host, so unblocking
     * `youtube.com` covers `m.youtube.com` — the coverage the per-site pause
     * had, since it paused the whole matching rule.
     */
    fun isUnblocked(type: String, id: String, nowElapsed: Long): Boolean {
        if (id.isEmpty()) return false
        for (g in snap.grants) {
            if (g.type != type || nowElapsed >= g.untilElapsed) continue
            val hit = if (type == TYPE_WEBSITE) {
                id == g.id || RuleEngine.isSubdomainOf(id, g.id)
            } else {
                id == g.id
            }
            if (hit) return true
        }
        return false
    }

    /**
     * Whether any grant of [type] is still live at [nowElapsed] — the hot-path
     * gate, so an event pays one volatile read and one long compare for the
     * overwhelmingly common case of no grants, and stops paying the per-event
     * scan again as soon as the last grant of that type lapses.
     *
     * Callers read `elapsedRealtime` once and pass it to this and to
     * [isUnblocked]; it is a vDSO read, not a binder call.
     */
    fun hasAny(type: String, nowElapsed: Long): Boolean = nowElapsed < when (type) {
        TYPE_APP -> snap.lastApp
        TYPE_REEL -> snap.lastReel
        TYPE_WEBSITE -> snap.lastWebsite
        else -> 0L
    }

    companion object {
        const val TYPE_REEL = "REEL"
        const val TYPE_APP = "APP"
        const val TYPE_WEBSITE = "WEBSITE"

        /** Dart prunes its ledger to the same number on every write. */
        const val MAX_GRANTS = 50

        /**
         * Wall-clock epoch deadline → monotonic deadline, resolved ONCE per parse
         * (every push and every service reconnect). A stamp already in the past
         * yields 0, i.e. not granted.
         *
         * The wall clock is trusted at this instant only, which is the right
         * trade: after a reboot `elapsedRealtime` restarts at 0 and the absolute
         * stamp is the only thing left to go on — and [ConfigStore] is re-read
         * on `onServiceConnected`, so every grant is re-anchored there. The
         * residual is a user who moves the clock back AND reboots; closing that
         * needs BOOT_COUNT and a persisted anchor (the EVO-048 ceiling).
         *
         * Lifted from `WebBlockEngine.toElapsedDeadline`, which this replaces —
         * one copy, not two.
         */
        fun toElapsedDeadline(endWall: Long, nowWall: Long, nowElapsed: Long): Long {
            if (endWall <= 0L) return 0L
            val remaining = endWall - nowWall
            return if (remaining > 0L) nowElapsed + remaining else 0L
        }

        /** Null when [json] is not a JSON array (keep the previous set); empty for blank. */
        private fun parse(json: String?, nowWall: Long, nowElapsed: Long): List<Grant>? {
            if (json.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(json)
                val count = minOf(arr.length(), MAX_GRANTS)
                val out = ArrayList<Grant>(count)
                for (i in 0 until count) {
                    val o = arr.optJSONObject(i) ?: continue
                    val type = o.optString("targetType")
                    if (type != TYPE_REEL && type != TYPE_APP && type != TYPE_WEBSITE) continue
                    val id = o.optString("targetId").trim().let {
                        if (type == TYPE_WEBSITE) it.lowercase() else it
                    }
                    if (id.isEmpty()) continue
                    val until = toElapsedDeadline(o.optLong("endMs", 0L), nowWall, nowElapsed)
                    if (until <= 0L) continue
                    out.add(Grant(type, id, until))
                }
                out
            } catch (_: Throwable) {
                null
            }
        }
    }
}
