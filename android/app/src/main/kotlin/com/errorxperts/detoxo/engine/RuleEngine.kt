package com.errorxperts.detoxo.engine

import org.json.JSONArray

/**
 * Enforces the rules snapshot Dart pushes over `pushRules`: schedules already
 * resolved to absolute windows, spent daily limits, and the daily reel limit's
 * native meter. MIRROR CONTRACT with Dart `SnapshotEntry.toJson`.
 *
 * Android-free (like [ReelTracker]) so the decision logic runs on the JVM. The
 * hot path is two long compares and a set lookup per entry — no parsing, no
 * calendar, no timezone. Dart owns the recurrence: it resolves windows in the
 * device zone and re-pushes on resume, on every rule change and at every
 * boundary (`ruleBoundary`). The first blocking entry wins.
 *
 * ponytail: windows are absolute and pushed 7 days ahead; with Detoxo unopened
 * for longer a schedule silently lapses until the next open. Upgrade path =
 * native recurrence evaluation.
 */
class RuleEngine {

    class Entry(
        val id: String,
        /** `SCHEDULE` | `DAILY_LIMIT` — the wall's `blockReason` token. */
        val reason: String,
        val allExcept: Boolean,
        val packages: Set<String>,
        val domains: List<String>,
        val platformIds: Set<String>,
        /** Flattened `[from0, until0, from1, until1, …]`, epoch ms, ignored when [always]. */
        val windows: LongArray,
        val always: Boolean,
        /** > 0: block the platforms once today's reel time reaches this (the daily reel limit). */
        val reelTimeLimitMs: Long,
        /** EVO-030: enforced ABOVE the pause gate — a Pause does not lift it. */
        val strict: Boolean = false,
        /** EVO-029: the rule's daily foreground budget in ms; 0 = not a time limit. */
        val usageLimitMs: Long = 0L,
        /** EVO-029: the rule's daily launch allowance; 0 = not an open limit. */
        val openLimitCount: Int = 0,
        /** EVO-029: whether that budget is already used up. */
        val spent: Boolean = false,
    ) {
        /** A meter entry applies to reel surfaces only — never to a package or a host. */
        val isReelMeter: Boolean get() = reelTimeLimitMs > 0L

        /** Carries a budget this build can measure itself. */
        val isMeteredLimit: Boolean get() = usageLimitMs > 0L || openLimitCount > 0

        /**
         * A budget that has NOT run out yet. Native measures it at the watchdog
         * tick and never blocks on it — the whole point of EVO-029 is that the
         * flip can happen with Detoxo closed, which is when Dart cannot.
         */
        val isPendingLimit: Boolean get() = isMeteredLimit && !spent

        /** This entry with [spent] forced true — snapshots stay immutable. */
        fun asSpent(): Entry = Entry(
            id, reason, allExcept, packages, domains, platformIds, windows,
            always, reelTimeLimitMs, strict, usageLimitMs, openLimitCount, spent = true,
        )

        fun isActive(now: Long): Boolean {
            if (always) return true
            var i = 0
            while (i + 1 < windows.size) {
                if (now >= windows[i] && now < windows[i + 1]) return true
                i += 2
            }
            return false
        }

        /**
         * When the window covering [now] closes, for the wall's "Unlocks at …"
         * line. 0 when nothing covers [now], or for an [always] entry — the
         * daily reel meter has no edge to name.
         */
        fun activeUntil(now: Long): Long {
            if (always) return 0L
            var i = 0
            while (i + 1 < windows.size) {
                if (now >= windows[i] && now < windows[i + 1]) return windows[i + 1]
                i += 2
            }
            return 0L
        }

        // ALL_EXCEPT inverts membership only within a LISTED dimension: an
        // empty list targets nothing, so a "block all except X" rule with only
        // platforms set never HOME-bounces every app on the phone.
        fun coversPackage(pkg: String): Boolean =
            packages.isNotEmpty() && ((pkg in packages) != allExcept)

        fun coversHost(host: String): Boolean {
            if (domains.isEmpty()) return false
            var hit = false
            for (d in domains) {
                if (host == d || isSubdomainOf(host, d)) {
                    hit = true
                    break
                }
            }
            return hit != allExcept
        }

        fun coversPlatform(platformId: String): Boolean =
            platformIds.isNotEmpty() &&
                ((ALL_PLATFORMS in platformIds || platformId in platformIds) != allExcept)
    }

    /**
     * The parsed snapshot and everything derived from it, swapped as ONE
     * reference: three separate @Volatile fields could be read half-updated by
     * a concurrent event (new entries, stale gates). [source] is the string it
     * was parsed from, so a re-push of an unchanged snapshot costs no parse —
     * spent-limit entries are built to be byte-identical across re-pushes, so
     * that is the common resume / boundary case.
     */
    private class Snapshot(val entries: List<Entry>, val source: String?) {
        val hasPackageRules =
            entries.any { !it.isReelMeter && !it.isPendingLimit && it.packages.isNotEmpty() }
        val hasHostRules = entries.any { !it.isPendingLimit && it.domains.isNotEmpty() }
        val hasReelMeter = entries.any { it.isReelMeter }
        val hasStrictRules = entries.any { it.strict && !it.isPendingLimit }
        val hasStrictPlatformRules =
            entries.any { it.strict && !it.isPendingLimit && it.platformIds.isNotEmpty() }
        val hasStrictHostRules =
            entries.any { it.strict && !it.isPendingLimit && it.domains.isNotEmpty() }
        val hasPendingLimits = entries.any { it.isPendingLimit }
    }

    @Volatile private var snap = Snapshot(emptyList(), null)

    /** Replace the snapshot. Blank clears; a malformed payload keeps the previous one. */
    fun setSnapshot(json: String?) {
        if (json == snap.source) return
        val parsed = parse(json) ?: return
        snap = Snapshot(parsed, json)
    }

    /**
     * Hot-path guard. NOTE: "no rules" is not "no entries" — a user with zero
     * rules but a global Daily Limit set still has the synthetic meter entry,
     * so this is true for them. Use [hasPackageRules] to gate the package arm.
     */
    fun hasAnyRules(): Boolean = snap.entries.isNotEmpty()

    /** Whether any entry names a package — gates the per-event package arm. */
    fun hasPackageRules(): Boolean = snap.hasPackageRules

    /** Whether any entry names a domain — gates the browser's host extraction. */
    fun hasHostRules(): Boolean = snap.hasHostRules

    /** Whether any entry meters reel time — gates the prefs read behind it. */
    fun hasReelMeter(): Boolean = snap.hasReelMeter

    /**
     * Whether any entry is strict — gates the pass that runs ABOVE the pause
     * gate. False for everyone who has not opted a rule in, so the extra pass
     * costs one volatile read.
     */
    fun hasStrictRules(): Boolean = snap.hasStrictRules

    /**
     * Whether a strict entry targets a REEL surface. This one has to open the
     * pause gate for the detection pass itself, so it is deliberately narrower
     * than [hasStrictRules]: without it a Pause skips detection entirely and a
     * strict reel rule would quietly not apply.
     */
    fun hasStrictPlatformRules(): Boolean = snap.hasStrictPlatformRules

    /**
     * Whether a strict entry targets a WEBSITE. The browser arm sits below the
     * pause gate, so — like [hasStrictPlatformRules] — this has to open that
     * gate for the host pass itself, or a strict rule's websites would quietly
     * not apply during a Pause. That was EVO-030's documented scope gap; M8
     * closed it, because a locked rule inherits `strict` and a lock whose
     * websites a 2-minute Pause frees is not a lock.
     */
    fun hasStrictHostRules(): Boolean = snap.hasStrictHostRules

    /** Whether anything needs re-measuring — gates the watchdog's UsageQuery. */
    fun hasPendingLimits(): Boolean = snap.hasPendingLimits

    /** The pending budgets, for the reconciler. */
    fun pendingLimits(): List<Entry> = snap.entries.filter { it.isPendingLimit }

    /**
     * Flip [ids] to spent, rebuilding the snapshot so every derived gate is
     * recomputed with them. Returns true when anything actually changed, so the
     * caller only persists and notifies on a real flip. [source] is dropped: the
     * in-memory snapshot no longer matches the pushed string, and Dart's next
     * push must re-parse and win.
     */
    fun markSpent(ids: Set<String>): Boolean {
        if (ids.isEmpty()) return false
        val current = snap
        var changed = false
        val next = current.entries.map { e ->
            if (e.id in ids && e.isPendingLimit) {
                changed = true
                e.asSpent()
            } else {
                e
            }
        }
        if (changed) snap = Snapshot(next, null)
        return changed
    }

    // Cheap predicate first in every arm: a set lookup rejects the entries that
    // don't name this target before the window scan walks up to 7 days of them.
    // Both predicates are pure, so the result is unchanged.
    fun blockingForPackage(pkg: String, now: Long, strictOnly: Boolean = false): Entry? {
        for (e in snap.entries) {
            if (strictOnly && !e.strict) continue
            if (e.isPendingLimit) continue
            if (!e.isReelMeter && e.coversPackage(pkg) && e.isActive(now)) return e
        }
        return null
    }

    /** [host] already normalized (lower-case, no scheme / `www.`). */
    fun blockingForHost(host: String, now: Long, strictOnly: Boolean = false): Entry? {
        if (host.isEmpty()) return null
        for (e in snap.entries) {
            if (strictOnly && !e.strict) continue
            if (e.isPendingLimit) continue
            if (!e.isReelMeter && e.coversHost(host) && e.isActive(now)) return e
        }
        return null
    }

    fun blockingForPlatform(
        platformId: String,
        now: Long,
        reelTimeTodayMs: Long,
        strictOnly: Boolean = false,
    ): Entry? {
        for (e in snap.entries) {
            if (strictOnly && !e.strict) continue
            if (e.isPendingLimit) continue
            if (!e.coversPlatform(platformId) || !e.isActive(now)) continue
            if (e.isReelMeter && reelTimeTodayMs < e.reelTimeLimitMs) continue
            return e
        }
        return null
    }

    companion object {
        const val ALL_PLATFORMS = "*"

        // Deliberate mirrors of BlockScreenPayload.REASON_SCHEDULE /
        // REASON_DAILY_LIMIT, NOT a missed dedupe: that type lives in
        // overlay/BlockScreenRenderer.kt, which imports android.*, and
        // referencing it here would drag the Android framework onto this
        // class's JVM test classpath. Rename in one place → rename in both.
        const val REASON_SCHEDULE = "SCHEDULE"
        const val REASON_DAILY_LIMIT = "DAILY_LIMIT"

        /**
         * Dart caps stored rules at 50 and appends the synthetic daily-reel-limit
         * entry AFTER them, so a legitimate snapshot is 51 long. Capping at 50
         * here truncated exactly that entry — the global Daily Limit — and
         * silently stopped enforcing it. Keep this at `maxRules + 1`.
         */
        const val MAX_ENTRIES = 51

        /** Null when [json] is not a JSON array (keep the previous snapshot); empty for blank. */
        fun parse(json: String?): List<Entry>? {
            if (json.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(json)
                val count = minOf(arr.length(), MAX_ENTRIES)
                val out = ArrayList<Entry>(count)
                for (i in 0 until count) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id")
                    if (id.isEmpty()) continue
                    val w = o.optJSONArray("windows")
                    var windows = LongArray((w?.length() ?: 0) * 2)
                    var n = 0
                    if (w != null) {
                        for (j in 0 until w.length()) {
                            val pair = w.optJSONArray(j) ?: continue
                            if (pair.length() < 2) continue
                            windows[n++] = pair.optLong(0)
                            windows[n++] = pair.optLong(1)
                        }
                    }
                    if (n != windows.size) windows = windows.copyOf(n)
                    out.add(
                        Entry(
                            id = id,
                            reason = o.optString("reason", REASON_SCHEDULE),
                            allExcept = o.optString("mode") == "ALL_EXCEPT",
                            packages = strings(o.optJSONArray("packages")).toHashSet(),
                            domains = strings(o.optJSONArray("domains")).map { it.lowercase() },
                            platformIds = strings(o.optJSONArray("platformIds")).toHashSet(),
                            windows = windows,
                            always = o.optBoolean("always", false),
                            reelTimeLimitMs = o.optLong("reelTimeLimitMs", 0L),
                            strict = o.optBoolean("strict", false),
                            usageLimitMs = o.optLong("usageLimitMs", 0L),
                            openLimitCount = o.optInt("openLimitCount", 0),
                            spent = o.optBoolean("spent", false),
                        ),
                    )
                }
                out
            } catch (_: Throwable) {
                null
            }
        }

        private fun strings(arr: JSONArray?): List<String> {
            if (arr == null) return emptyList()
            val out = ArrayList<String>(arr.length())
            for (i in 0 until arr.length()) {
                val s = arr.optString(i).trim()
                if (s.isNotEmpty()) out.add(s)
            }
            return out
        }

        /** Allocation-free `host.endsWith(".$pattern")` — the WebBlockEngine rule. */
        fun isSubdomainOf(host: String, pattern: String): Boolean =
            host.length > pattern.length &&
                host[host.length - pattern.length - 1] == '.' &&
                host.endsWith(pattern)
    }
}
