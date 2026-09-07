package com.errorxperts.detoxo.engine

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Single source of truth for the native engine's configuration and settings.
 *
 * Dart pushes the platforms-config JSON and the user's settings here; the
 * AccessibilityService reads them. Backed by ordinary SharedPreferences (the
 * service runs in the main process, so no multi-process mode is required).
 */
class ConfigStore(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // The ~31 KB platforms config lives in its OWN prefs file: every .apply()
    // re-serialises the whole file, and the hot path writes counters into
    // [PREFS] constantly — sharing a file meant multi-KB disk writes at scroll
    // frequency.
    private val configPrefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(CONFIG_PREFS, Context.MODE_PRIVATE)

    // The rules snapshot gets its own file for the same reason: measured
    // against the shipped catalog it is ~45 KB typical and ~175 KB worst case
    // at the 50-rule cap (a category flattens to every package AND domain in
    // it), while the counter flushes usage into [PREFS] every 5 s — which would
    // re-serialise the snapshot with it, 12×/min, for the whole session.
    private val rulesPrefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(RULES_PREFS, Context.MODE_PRIVATE)

    init {
        // One-time idempotent migration of the config out of the hot file.
        prefs.getString(KEY_CONFIG, null)?.let { legacy ->
            if (!configPrefs.contains(KEY_CONFIG)) {
                configPrefs.edit().putString(KEY_CONFIG, legacy).apply()
            }
            prefs.edit().remove(KEY_CONFIG).apply()
        }
        // Same, for the rules snapshot: an upgrade keeps enforcing without
        // waiting for Dart's next push.
        prefs.getString(KEY_RULES, null)?.let { legacy ->
            if (!rulesPrefs.contains(KEY_RULES)) {
                rulesPrefs.edit().putString(KEY_RULES, legacy).apply()
            }
            prefs.edit().remove(KEY_RULES).apply()
        }
    }

    var platformsConfigJson: String?
        get() = configPrefs.getString(KEY_CONFIG, null)
        set(value) = configPrefs.edit().putString(KEY_CONFIG, value).apply()

    var activePlan: String
        get() = prefs.getString(KEY_PLAN, "BLOCK_ALL") ?: "BLOCK_ALL"
        set(value) = prefs.edit().putString(KEY_PLAN, value).apply()

    var defaultBlockMode: String
        get() = prefs.getString(KEY_BLOCK_MODE, "PRESS_BACK") ?: "PRESS_BACK"
        set(value) = prefs.edit().putString(KEY_BLOCK_MODE, value).apply()

    /** Set of enabled platformIds (e.g. "ig_reel", "yt_shorts"). */
    var enabledPlatforms: Set<String>
        get() = prefs.getStringSet(KEY_ENABLED, emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet(KEY_ENABLED, value).apply()

    /**
     * Packages Detoxo must completely ignore (privacy-protected apps: banking,
     * UPI, password managers…). While one is foreground the service does no
     * counting, no reading, no blocking. Overrides the monitored catalog.
     */
    var protectedPackages: Set<String>
        get() = prefs.getStringSet(KEY_PROTECTED, emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet(KEY_PROTECTED, value).apply()

    var vibrationEnabled: Boolean
        get() = prefs.getBoolean(KEY_VIBRATION, true)
        set(value) = prefs.edit().putBoolean(KEY_VIBRATION, value).apply()

    var masterEnabled: Boolean
        get() = prefs.getBoolean(KEY_MASTER, true)
        set(value) = prefs.edit().putBoolean(KEY_MASTER, value).apply()

    /** Epoch millis until which blocking is paused (0 = not paused). */
    var pauseUntil: Long
        get() = prefs.getLong(KEY_PAUSE_UNTIL, 0L)
        set(value) = prefs.edit().putLong(KEY_PAUSE_UNTIL, value).apply()

    // ── Website blocking ────────────────────────────────────────────────────

    /** The active website blocklist (JSON `[{pattern,matchType}]`), or null. */
    var webBlocklistJson: String?
        get() = prefs.getString(KEY_WEB_BLOCKLIST, null)
        set(value) = prefs.edit().putString(KEY_WEB_BLOCKLIST, value).apply()

    /** Whether the bundled adult-domain set is enforced. */
    var blockAdultWebsites: Boolean
        get() = prefs.getBoolean(KEY_BLOCK_ADULT, false)
        set(value) = prefs.edit().putBoolean(KEY_BLOCK_ADULT, value).apply()

    /** Whether websites of blocked apps are enforced (rules are Dart-derived). */
    var blockWebsitesForBlockedApps: Boolean
        get() = prefs.getBoolean(KEY_BLOCK_FOR_APPS, false)
        set(value) = prefs.edit().putBoolean(KEY_BLOCK_FOR_APPS, value).apply()

    // ── Notification suppression ────────────────────────────────────────────

    /**
     * Whether notifications from currently-blocked apps are cancelled. OFF by
     * default and opt-in: it needs a separate, broader grant than everything
     * else here (see `DetoxoNotificationListener`). The suppressed set itself is
     * never stored — it is derived per notification from the live engine state.
     */
    var suppressNotifications: Boolean
        get() = prefs.getBoolean(KEY_SUPPRESS_NOTIFS, false)
        set(value) = prefs.edit().putBoolean(KEY_SUPPRESS_NOTIFS, value).apply()

    /** Counter for website blocks (kept separate from the reel block counter). */
    fun recordWebBlock(dateKey: String) {
        val storedDate = prefs.getString(KEY_WEB_BLOCK_DATE, "")
        val todayCount = if (storedDate == dateKey) prefs.getInt(KEY_WEB_BLOCK_TODAY, 0) else 0
        prefs.edit()
            .putString(KEY_WEB_BLOCK_DATE, dateKey)
            .putInt(KEY_WEB_BLOCK_TODAY, todayCount + 1)
            .putInt(KEY_WEB_BLOCK_TOTAL, prefs.getInt(KEY_WEB_BLOCK_TOTAL, 0) + 1)
            .apply()
    }

    /**
     * (today, total) website block counts for [dateKey]. Read-time rollover
     * (mirrors [ContentCounterStore.snapshot]): a stale stored date reads
     * today as 0 without writing — the next [recordWebBlock] does the durable
     * reset.
     */
    fun webBlockStats(dateKey: String): Pair<Int, Int> = Pair(
        if (prefs.getString(KEY_WEB_BLOCK_DATE, "") == dateKey) {
            prefs.getInt(KEY_WEB_BLOCK_TODAY, 0)
        } else {
            0
        },
        prefs.getInt(KEY_WEB_BLOCK_TOTAL, 0),
    )

    // ── Conscious (earn-as-you-abstain token bucket) ────────────────────────
    //
    // In Conscious mode the user banks allowance while abstaining and spends it
    // while watching. The engine owns this balance so it keeps ticking when the
    // Flutter UI is dead. `bank` drains 1:1 while a reel is on screen and refills
    // at `1 / earnDivisor` of elapsed time while abstaining, capped at `maxBank`.

    /**
     * Currently banked Conscious allowance, in millis (0..maxBank). The live
     * value is cached and write-batched inside the service (its 1 Hz accountant
     * must not write prefs per tick); this is the durable copy, at most ~5s
     * behind while the accountant runs. The tick anchor is runtime-only in the
     * service — a restart re-anchors to now.
     */
    var consciousBankMs: Long
        get() = prefs.getLong(KEY_CONSCIOUS_BANK, 0L)
        set(value) = prefs.edit().putLong(KEY_CONSCIOUS_BANK, value).apply()

    /** Earn divisor: bank += elapsed / divisor while abstaining (default 10). */
    var consciousEarnDivisor: Int
        get() = prefs.getInt(KEY_CONSCIOUS_DIVISOR, 10).coerceAtLeast(1)
        set(value) = prefs.edit().putInt(KEY_CONSCIOUS_DIVISOR, value.coerceAtLeast(1)).apply()

    /** Maximum banked allowance, in millis (default 10 min). */
    var consciousMaxBankMs: Long
        get() = prefs.getLong(KEY_CONSCIOUS_MAX, 600_000L).coerceAtLeast(0L)
        set(value) = prefs.edit().putLong(KEY_CONSCIOUS_MAX, value.coerceAtLeast(0L)).apply()

    /** Begin a fresh Conscious session: empty bank. */
    fun resetConsciousBank() {
        prefs.edit().putLong(KEY_CONSCIOUS_BANK, 0L).apply()
    }

    // ── One Reel / Unblock (allow N reels, then re-block) ────────────────────
    //
    // In these modes the user is granted a fixed [reelAllowance] of reels; the
    // engine counts distinct reels ([reelsConsumed], scroll-delimited) and blocks
    // once the allowance is spent. Re-armed on every mode tap via
    // [resetReelSession]. `reelsConsumed` is PERSISTED so an OS-driven service
    // restart can't silently grant a free reel without a fresh re-tap.

    /** Reels allowed before One Reel / Unblock re-blocks (1..20; One Reel = 1). */
    var reelAllowance: Int
        get() = prefs.getInt(KEY_REEL_ALLOWANCE, 1).coerceIn(1, 20)
        set(value) = prefs.edit().putInt(KEY_REEL_ALLOWANCE, value.coerceIn(1, 20)).apply()

    /** Distinct reels consumed this session (0..reelAllowance). */
    var reelsConsumed: Int
        get() = prefs.getInt(KEY_REELS_CONSUMED, 0).coerceAtLeast(0)
        set(value) = prefs.edit().putInt(KEY_REELS_CONSUMED, value.coerceAtLeast(0)).apply()

    /** Begin a fresh One Reel / Unblock session: zero the consumed count. */
    fun resetReelSession() {
        prefs.edit().putInt(KEY_REELS_CONSUMED, 0).apply()
    }

    /**
     * One block of [pkg] on [dateKey]. Besides today/total, the per-package
     * tally (EVO-059) rides the same day and the same rollover; on a day
     * change the count that was "today" is rotated into yesterday's slot
     * (EVO-060) — if the stored day really was [yesterdayKey], else yesterday
     * had no blocks and the slot records 0.
     */
    fun recordBlock(dateKey: String, yesterdayKey: String, pkg: String) {
        val storedDate = prefs.getString(KEY_BLOCK_DATE, "") ?: ""
        val sameDay = storedDate == dateKey
        val storedToday = prefs.getInt(KEY_BLOCK_TODAY, 0)
        val todayCount = if (sameDay) storedToday else 0
        val edit = prefs.edit()
        if (!sameDay) {
            edit.putString(KEY_BLOCK_YESTERDAY_DATE, yesterdayKey)
                .putInt(KEY_BLOCK_YESTERDAY, if (storedDate == yesterdayKey) storedToday else 0)
        }
        edit.putString(KEY_BLOCK_DATE, dateKey)
            .putInt(KEY_BLOCK_TODAY, todayCount + 1)
            .putInt(KEY_BLOCK_TOTAL, prefs.getInt(KEY_BLOCK_TOTAL, 0) + 1)
            .putString(
                KEY_BLOCK_BY_PKG,
                BlockTally.record(if (sameDay) prefs.getString(KEY_BLOCK_BY_PKG, null) else null, pkg),
            )
            .apply()
    }

    /**
     * Block counts for [dateKey]. Read-time rollover as in [webBlockStats]:
     * after midnight, today (and its per-package tally) read 0 / empty before
     * the day's first block instead of yesterday's numbers, and yesterday is
     * derived from whatever the store holds ([BlockTally.yesterday]).
     */
    fun blockStats(dateKey: String, yesterdayKey: String): BlockStats {
        val storedDate = prefs.getString(KEY_BLOCK_DATE, "") ?: ""
        val sameDay = storedDate == dateKey
        val storedToday = prefs.getInt(KEY_BLOCK_TODAY, 0)
        return BlockStats(
            today = if (sameDay) storedToday else 0,
            total = prefs.getInt(KEY_BLOCK_TOTAL, 0),
            date = dateKey,
            yesterday = BlockTally.yesterday(
                storedDate = storedDate,
                storedToday = storedToday,
                rotatedDate = prefs.getString(KEY_BLOCK_YESTERDAY_DATE, "") ?: "",
                rotatedCount = prefs.getInt(KEY_BLOCK_YESTERDAY, 0),
                todayKey = dateKey,
                yesterdayKey = yesterdayKey,
            ),
            byPackage = if (sameDay) BlockTally.parse(prefs.getString(KEY_BLOCK_BY_PKG, null)) else emptyMap(),
        )
    }

    /**
     * A newly protected app leaves today's tally as well as tomorrow's
     * (`docs/code_docs/24-protected-apps.md`: nothing about it is stored).
     * No write unless one of [packages] was actually named.
     */
    fun scrubBlockTally(packages: Set<String>) {
        BlockTally.without(prefs.getString(KEY_BLOCK_BY_PKG, null), packages)?.let {
            prefs.edit().putString(KEY_BLOCK_BY_PKG, it).apply()
        }
    }

    // ── Custom whole-app blocks ─────────────────────────────────────────────

    /** Packages the user locked entirely: opening one bounces the user HOME. */
    var blockedAppPackages: Set<String>
        get() = prefs.getStringSet(KEY_APP_BLOCKLIST, emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet(KEY_APP_BLOCKLIST, value).apply()

    // ── Soft nudge ──────────────────────────────────────────────────────────

    /** Whether the advisory dwell nudge runs at all. Off until asked for. */
    var nudgeEnabled: Boolean
        get() = prefs.getBoolean(KEY_NUDGE_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_NUDGE_ENABLED, value).apply()

    /**
     * Apps that nudge — the catalog's `distracting` behaviour, derived in Dart
     * and pushed flat. Distinct from every blocklist here: these apps are not
     * blocked, they are only counted while they are open.
     */
    var nudgePackages: Set<String>
        get() = prefs.getStringSet(KEY_NUDGE_PACKAGES, emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet(KEY_NUDGE_PACKAGES, value).apply()

    /** Minutes between nudges, as ms. Clamped: a 10 s nudge is a punishment. */
    var nudgeStepMs: Long
        get() = prefs.getLong(KEY_NUDGE_STEP, NudgeTracker.THRESHOLD_STEP_MS)
            .coerceIn(60_000L, 3_600_000L)
        set(value) = prefs.edit()
            .putLong(KEY_NUDGE_STEP, value.coerceIn(60_000L, 3_600_000L)).apply()

    /** Nudges per app per day before the machine goes quiet. */
    var nudgeDailyCap: Int
        get() = prefs.getInt(KEY_NUDGE_CAP, NudgeTracker.DAILY_CAP).coerceIn(1, 50)
        set(value) = prefs.edit().putInt(KEY_NUDGE_CAP, value.coerceIn(1, 50)).apply()

    // ── Watchdog ────────────────────────────────────────────────────────────

    /** The accessibility service connected at least once on this install. */
    var serviceEverConnected: Boolean
        get() = prefs.getBoolean(KEY_SERVICE_CONNECTED, false)
        set(value) = prefs.edit().putBoolean(KEY_SERVICE_CONNECTED, value).apply()

    /** Last "Protection stopped" notification (epoch ms) — re-notify debounce. */
    var lastWatchdogNotifiedMs: Long
        get() = prefs.getLong(KEY_WATCHDOG_NOTIFIED, 0L)
        set(value) = prefs.edit().putLong(KEY_WATCHDOG_NOTIFIED, value).apply()

    /** Day key of the last Conscious accounting tick — the bank resets daily. */
    var consciousDate: String
        get() = prefs.getString(KEY_CONSCIOUS_DATE, "") ?: ""
        set(value) = prefs.edit().putString(KEY_CONSCIOUS_DATE, value).apply()

    /**
     * Block-screen appearance + its on/off switch as a JSON string (see Dart
     * `BlockScreenStyle.toWire`). Read once per debounced block in
     * `BlockScreenOverlay.show`, never per accessibility event.
     */
    var blockScreenStyleJson: String
        get() = prefs.getString(KEY_BLOCK_SCREEN_STYLE, "") ?: ""
        set(value) = prefs.edit().putString(KEY_BLOCK_SCREEN_STYLE, value).apply()

    // ── Rules (schedules / daily limits) ────────────────────────────────────

    /**
     * The resolved rules snapshot Dart pushes (`pushRules`, a JSON array), or
     * null. Read by [RuleEngine] on push / reload, never per event. Lives in
     * its own [RULES_PREFS] file — see the field comment for the size that put
     * it there. Migrated out of [PREFS] once, on first construction.
     */
    var rulesJson: String?
        get() = rulesPrefs.getString(KEY_RULES, null)
        set(value) = rulesPrefs.edit().putString(KEY_RULES, value).apply()

    /**
     * Earliest moment any pushed rule window opens or closes (0 = none).
     * Zeroed once `ruleBoundary` has been posted; Dart's re-push arms the next.
     */
    var nextBoundaryMs: Long
        get() = prefs.getLong(KEY_NEXT_BOUNDARY, 0L)
        set(value) = prefs.edit().putLong(KEY_NEXT_BOUNDARY, value).apply()

    // ── Temporary unblocks (M8) ─────────────────────────────────────────────

    /**
     * The active per-target grants Dart pushes (`pushTemporaryUnblocks`, a JSON
     * array `[{targetType,targetId,endMs}]`), or null. Read by [UnblockRegistry]
     * on push / reload, never per event. Bounded at
     * [UnblockRegistry.MAX_GRANTS] on both sides, so unlike the rules snapshot
     * it is small enough to share the hot [PREFS] file.
     */
    var temporaryUnblocksJson: String?
        get() = prefs.getString(KEY_TEMP_UNBLOCKS, null)
        set(value) = prefs.edit().putString(KEY_TEMP_UNBLOCKS, value).apply()

    /**
     * EVO-050: a grant the user took **on the wall**, without leaving the app.
     *
     * Written to two places on purpose. The enforced list so the block lifts on
     * this event rather than after a round trip through Dart, and a small
     * hand-off list so Dart can fold it into Hive — which stays the canonical
     * store, because it is the one that holds history, survives a native cache
     * clear, and Dart's own push rewrites [temporaryUnblocksJson] wholesale.
     * Without the second key that push would silently delete the grant the user
     * just took.
     *
     * Returns false when the payload could not be written, so the caller can
     * fall back to the pending-intent hand-off instead of pretending it worked.
     */
    fun appendGrant(type: String, id: String, endMs: Long): Boolean {
        if (type.isEmpty() || id.isEmpty() || endMs <= 0L) return false
        val row = JSONObject()
            .put("targetType", type)
            .put("targetId", id)
            .put("endMs", endMs)
        return runCatching {
            prefs.edit()
                .putString(KEY_TEMP_UNBLOCKS, appendTo(temporaryUnblocksJson, row, type, id))
                .putString(KEY_NATIVE_GRANTS, appendTo(nativeGrantsJson, row, type, id))
                .apply()
        }.isSuccess
    }

    /** Grants native took on the wall, for Dart to absorb. Cleared by [takeNativeGrants]. */
    private val nativeGrantsJson: String?
        get() = prefs.getString(KEY_NATIVE_GRANTS, null)

    /** Read-and-clear, the [takePendingUnblock] contract. */
    fun takeNativeGrants(): String? {
        val raw = nativeGrantsJson
        prefs.edit().remove(KEY_NATIVE_GRANTS).apply()
        return raw
    }

    /**
     * [row] prepended to [json], with any existing row for the same target
     * dropped — a second grant on one target REPLACES the first, exactly as
     * `UnblockCubit.grant` does, so the two writers cannot disagree about what
     * "already free" means. Capped at the registry's own limit.
     */
    private fun appendTo(json: String?, row: JSONObject, type: String, id: String): String {
        val out = JSONArray().put(row)
        val existing = runCatching { JSONArray(json ?: "[]") }.getOrNull() ?: JSONArray()
        for (i in 0 until existing.length()) {
            if (out.length() >= UnblockRegistry.MAX_GRANTS) break
            val o = existing.optJSONObject(i) ?: continue
            if (o.optString("targetType") == type && o.optString("targetId") == id) continue
            out.put(o)
        }
        return out.toString()
    }

    /**
     * Arm the wall's "Unblock for a while" tap for Dart, stored as
     * `"TYPE|id|stamp"`. Read back exactly once by [takePendingUnblock], which
     * clears it and hands Dart the `"TYPE|id"` pair it expects — the stamp
     * never crosses the channel.
     *
     * A SharedPreferences key rather than a replayed event: the wall's tap also
     * launches Detoxo, and on a cold start the EventChannel sink does not exist
     * yet, so a non-sticky event is dropped. Making the action sticky instead
     * would re-fire an unrequested bypass sheet on the next engine attach.
     */
    fun setPendingUnblock(type: String, id: String, nowMs: Long) {
        prefs.edit().putString(KEY_PENDING_UNBLOCK, "$type|$id|$nowMs").apply()
    }

    /**
     * The armed tap, or null. Always clears.
     *
     * The stamp is why this is a function and not a var: `launchDetoxo`
     * swallows its own failure, and the user can swipe Detoxo away before the
     * drain — either way the key survived, and days later an unrelated launch
     * opened a duration sheet nobody asked for, one tap away from an hour-long
     * bypass. Outside the window it is dropped silently. A backwards clock
     * yields a negative age, which is also outside the window: fail-safe.
     */
    fun takePendingUnblock(nowMs: Long): String? {
        val raw = prefs.getString(KEY_PENDING_UNBLOCK, null)
        prefs.edit().remove(KEY_PENDING_UNBLOCK).apply()
        val parts = raw?.split('|') ?: return null
        if (parts.size != 3 || parts[0].isEmpty() || parts[1].isEmpty()) return null
        val age = nowMs - (parts[2].toLongOrNull() ?: return null)
        if (age < 0L || age > PENDING_UNBLOCK_TTL_MS) return null
        return "${parts[0]}|${parts[1]}"
    }

    companion object {
        /**
         * How long an armed "Unblock for a while" tap stays valid. Generous
         * next to the launch it triggers (the drain runs in bootstrap, seconds
         * later) and still short enough that a launch which never happened
         * cannot follow the user into another day.
         */
        const val PENDING_UNBLOCK_TTL_MS = 2 * 60 * 1000L

        private const val PREFS = "detoxo_engine_prefs"
        private const val CONFIG_PREFS = "detoxo_platforms_config"
        private const val RULES_PREFS = "detoxo_rules_snapshot"
        private const val KEY_CONFIG = "platforms_config_json"
        private const val KEY_APP_BLOCKLIST = "app_blocklist_packages"
        private const val KEY_SERVICE_CONNECTED = "service_ever_connected"
        private const val KEY_WATCHDOG_NOTIFIED = "last_watchdog_notified_ms"
        private const val KEY_CONSCIOUS_DATE = "conscious_date"
        private const val KEY_PLAN = "active_plan"
        private const val KEY_BLOCK_MODE = "default_block_mode"
        private const val KEY_ENABLED = "enabled_platforms"
        private const val KEY_PROTECTED = "protected_packages"
        private const val KEY_VIBRATION = "vibration_enabled"
        private const val KEY_MASTER = "master_enabled"
        private const val KEY_PAUSE_UNTIL = "pause_until"
        private const val KEY_CONSCIOUS_BANK = "conscious_bank_ms"
        private const val KEY_CONSCIOUS_DIVISOR = "conscious_earn_divisor"
        private const val KEY_CONSCIOUS_MAX = "conscious_max_bank_ms"
        private const val KEY_REEL_ALLOWANCE = "reel_allowance"
        private const val KEY_REELS_CONSUMED = "reels_consumed"
        private const val KEY_BLOCK_DATE = "block_date"
        private const val KEY_BLOCK_TODAY = "block_today"
        private const val KEY_BLOCK_TOTAL = "block_total"
        private const val KEY_BLOCK_YESTERDAY = "block_yesterday"
        private const val KEY_BLOCK_YESTERDAY_DATE = "block_yesterday_date"
        private const val KEY_BLOCK_BY_PKG = "block_by_pkg_today"
        private const val KEY_WEB_BLOCKLIST = "web_blocklist_json"
        private const val KEY_BLOCK_ADULT = "block_adult_websites"
        private const val KEY_BLOCK_FOR_APPS = "block_websites_for_blocked_apps"
        private const val KEY_SUPPRESS_NOTIFS = "suppress_notifications"
        private const val KEY_WEB_BLOCK_DATE = "web_block_date"
        private const val KEY_WEB_BLOCK_TODAY = "web_block_today"
        private const val KEY_WEB_BLOCK_TOTAL = "web_block_total"
        private const val KEY_BLOCK_SCREEN_STYLE = "block_screen_style"
        private const val KEY_RULES = "rules_json"
        private const val KEY_NEXT_BOUNDARY = "next_boundary_ms"
        private const val KEY_NUDGE_ENABLED = "nudge_enabled"
        private const val KEY_NUDGE_PACKAGES = "nudge_packages"
        private const val KEY_NUDGE_STEP = "nudge_step_ms"
        private const val KEY_NUDGE_CAP = "nudge_daily_cap"
        private const val KEY_TEMP_UNBLOCKS = "temporary_unblocks_json"
        private const val KEY_PENDING_UNBLOCK = "pending_unblock"
        private const val KEY_NATIVE_GRANTS = "native_grants_json"
    }
}
