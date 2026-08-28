package com.errorxperts.detoxo.engine

import android.content.Context
import android.content.SharedPreferences

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

    init {
        // One-time idempotent migration of the config out of the hot file.
        prefs.getString(KEY_CONFIG, null)?.let { legacy ->
            if (!configPrefs.contains(KEY_CONFIG)) {
                configPrefs.edit().putString(KEY_CONFIG, legacy).apply()
            }
            prefs.edit().remove(KEY_CONFIG).apply()
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

    fun recordBlock(dateKey: String) {
        val storedDate = prefs.getString(KEY_BLOCK_DATE, "")
        val todayCount = if (storedDate == dateKey) prefs.getInt(KEY_BLOCK_TODAY, 0) else 0
        prefs.edit()
            .putString(KEY_BLOCK_DATE, dateKey)
            .putInt(KEY_BLOCK_TODAY, todayCount + 1)
            .putInt(KEY_BLOCK_TOTAL, prefs.getInt(KEY_BLOCK_TOTAL, 0) + 1)
            .apply()
    }

    /**
     * (today, total, date) block counts for [dateKey]. Read-time rollover as in
     * [webBlockStats]: after midnight, today reads 0 before the day's first
     * block instead of yesterday's number.
     */
    fun blockStats(dateKey: String): Triple<Int, Int, String> = Triple(
        if (prefs.getString(KEY_BLOCK_DATE, "") == dateKey) {
            prefs.getInt(KEY_BLOCK_TODAY, 0)
        } else {
            0
        },
        prefs.getInt(KEY_BLOCK_TOTAL, 0),
        dateKey,
    )

    // ── Custom whole-app blocks ─────────────────────────────────────────────

    /** Packages the user locked entirely: opening one bounces the user HOME. */
    var blockedAppPackages: Set<String>
        get() = prefs.getStringSet(KEY_APP_BLOCKLIST, emptySet()) ?: emptySet()
        set(value) = prefs.edit().putStringSet(KEY_APP_BLOCKLIST, value).apply()

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

    companion object {
        private const val PREFS = "detoxo_engine_prefs"
        private const val CONFIG_PREFS = "detoxo_platforms_config"
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
        private const val KEY_WEB_BLOCKLIST = "web_blocklist_json"
        private const val KEY_BLOCK_ADULT = "block_adult_websites"
        private const val KEY_BLOCK_FOR_APPS = "block_websites_for_blocked_apps"
        private const val KEY_WEB_BLOCK_DATE = "web_block_date"
        private const val KEY_WEB_BLOCK_TODAY = "web_block_today"
        private const val KEY_WEB_BLOCK_TOTAL = "web_block_total"
    }
}
