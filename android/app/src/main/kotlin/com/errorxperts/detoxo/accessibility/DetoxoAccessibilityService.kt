package com.errorxperts.detoxo.accessibility

import android.accessibilityservice.AccessibilityService
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.errorxperts.detoxo.R
import com.errorxperts.detoxo.admin.DetoxoDeviceAdminReceiver
import com.errorxperts.detoxo.engine.BrowserUrlExtractor
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ContentCounter
import com.errorxperts.detoxo.engine.DateKeys
import com.errorxperts.detoxo.engine.DetectionConfig
import com.errorxperts.detoxo.engine.DetectorRule
import com.errorxperts.detoxo.engine.PlatformRule
import com.errorxperts.detoxo.engine.ServiceEventBus
import com.errorxperts.detoxo.engine.WebBlockEngine
import com.errorxperts.detoxo.engine.recycleSafe
import com.errorxperts.detoxo.receivers.WatchdogJobService
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap

/**
 * The detection + block engine. Verified behaviour from the reference app:
 *  - per-package event throttle (150 ms)
 *  - active-plan gate (paused window suspends blocking)
 *  - 3-stage view-id detection (source check -> findByViewId -> DFS, cap 12000)
 *  - block execution with a 1200 ms debounce and a 1100 ms back rate-limit
 */
class DetoxoAccessibilityService : AccessibilityService() {

    private lateinit var store: ConfigStore
    @Volatile private var config: DetectionConfig = DetectionConfig.EMPTY

    // ── Privacy-protected apps ────────────────────────────────────────────────
    // While a protected app (banking/UPI/password manager…) is foreground the
    // service must do nothing at all: no counting, no URL reads, no tree walks,
    // no blocking, no BACK presses. Cached from ConfigStore so the hot path
    // never touches SharedPreferences; refreshed by reload().
    @Volatile private var protectedPkgs: Set<String> = emptySet()

    /** THE privacy decision: Detoxo does nothing at all for a protected app. */
    private fun isProtected(pkg: String?): Boolean = pkg != null && pkg in protectedPkgs

    /**
     * Second privacy anchor: the active window's own package. Immune to a
     * stale or clobbered [foregroundPkg] (null after a service reconnect, or
     * overwritten by a transient IME/system window while a protected app is
     * on screen) — a tree whose root is protected is never walked, and no
     * BACK/lock ever fires into it.
     */
    private fun activeWindowProtected(root: AccessibilityNodeInfo?): Boolean =
        isProtected(root?.packageName?.toString())

    /**
     * Cheap refresh for protected-apps pushes: re-reads only the set — no
     * detection-config re-parse, no Conscious/bubble re-sync (that is
     * [reload]'s job, and pushes of an unchanged set skip even this).
     */
    fun refreshProtectedPackages() {
        protectedPkgs = store.protectedPackages
    }

    private val lastEventByPackage = ConcurrentHashMap<String, Long>()
    @Volatile private var lastBlockTime = 0L
    @Volatile private var lastBackTime = 0L

    // ── Custom whole-app blocks ───────────────────────────────────────────────
    // Packages the user locked entirely (pushed via pushAppBlocklist). Cached
    // so the hot path never touches SharedPreferences; refreshed by reload()
    // and refreshAppBlocklist(). Own debounce — a whole-app bounce must not
    // consume the reel-block window (or vice versa).
    @Volatile private var blockedApps: Set<String> = emptySet()
    @Volatile private var lastAppBlockTime = 0L

    /**
     * Every HOME-capable package, not just the current default: a stale
     * blocklist must never bounce a launcher, and `resolveActivity` hands back
     * the resolver (package "android") while no default is chosen.
     */
    @Volatile private var homePkgs: Set<String> = emptySet()

    /**
     * Cheap refresh for pushAppBlocklist (mirrors [refreshProtectedPackages]).
     * Re-resolves the launcher guard too — the user may have switched
     * launchers since the last full [reload].
     */
    fun refreshAppBlocklist() {
        blockedApps = store.blockedAppPackages
        homePkgs = homePackages()
    }

    /** Cheap refresh for pushWebBlocklist: the rule set only, no config re-parse. */
    fun refreshWebBlocklist() {
        webEngine.setBlocklist(store.webBlocklistJson)
    }

    // ── Hot-path settings cache ──────────────────────────────────────────────
    // Mirrors of the per-event settings flags, same pattern as [protectedPkgs]:
    // the event path touches no SharedPreferences. Safe because every write
    // goes through CommandHandler, which always follows with reload().
    @Volatile private var masterOn = true
    @Volatile private var pausedUntil = 0L
    @Volatile private var activePlan = ""
    @Volatile private var enabledPlatformIds: Set<String> = emptySet()

    // ── Conscious bank cache + write batching ────────────────────────────────
    // The 1 Hz accountant used to do two prefs .apply() per tick (anchor +
    // bank ≈ 172k writes/day in Conscious). The bank now lives here and
    // flushes at most every CONSCIOUS_FLUSH_MS (forced when it empties, on
    // plan stop, on reload and on unbind/destroy). The anchor is runtime-only:
    // a service restart re-anchors to now anyway (see [syncConscious]).
    // ponytail: <=5s of earned bank lost on a hard process kill.
    @Volatile private var consciousBank = 0L
    private var consciousDirty = false
    private var lastConsciousFlushMs = 0L
    private var consciousAnchorMs = 0L

    // Per-event detector-match memo: the counting pass and the block pass test
    // the same detectors against the same window — the second pass becomes map
    // lookups instead of a second full tree walk. Cleared per event; events are
    // delivered serially on the main thread, so no locking.
    private val matchMemo = HashMap<DetectorRule, Boolean>()

    // ── Short-video awareness counter ─────────────────────────────────────────
    // Counts reels/shorts across supported apps independent of blocking. Public
    // so CommandHandler can reach it via the service instance.
    val contentCounter by lazy { ContentCounter(this) }
    private val lastCountEventByPackage = ConcurrentHashMap<String, Long>()

    // ── Website blocking ──────────────────────────────────────────────────────
    private val webEngine by lazy { WebBlockEngine(this) }
    // Last seen host per browser package — avoids re-pressing back on a host that
    // is still on screen while the back navigation settles.
    private val lastUrlByPkg = ConcurrentHashMap<String, String>()
    @Volatile private var lastWebBlockTime = 0L

    // ── Conscious (earn-as-you-abstain) ──────────────────────────────────────
    // A 1 Hz accountant runs while the active plan is Conscious so the bank keeps
    // ticking even when the Flutter UI is dead.
    private val consciousHandler = Handler(Looper.getMainLooper())
    private var consciousRunning = false
    @Volatile private var lastReelAtMs = 0L

    // ── One Reel / Unblock (allow N reels, then block) ───────────────────────
    // Runtime-only dwell state (meaningless across a service restart); the
    // consumed count is persisted in ConfigStore so a restart keeps the user
    // blocked until an explicit re-tap, and these self-correct from it.
    //  - `lastScrollAtMs`  : a reel-advance scroll (captured pre-throttle).
    //  - `reelViewStartMs` : when the current reel view began (0 = none/fresh).
    //  - `reelViewCounted` : the current reel already cost one count (loop-safe).
    //  - `lastReelCountMs` : when the last reel was counted (debounces in-reel
    //    scrolls, e.g. opening comments, from being read as a reel advance).
    // A reel counts toward the allowance only after MIN_VIEW_MS (2s) of dwell, so
    // a quick flick-through or a single looping reel costs at most one count.
    @Volatile private var lastScrollAtMs = 0L
    @Volatile private var reelViewStartMs = 0L
    @Volatile private var reelViewCounted = false
    @Volatile private var lastReelCountMs = 0L
    // Foreground package, tracked for the Conscious accountant: "abstaining"
    // means the foreground app has no reel surfaces, so the bank only accrues
    // when the user is genuinely off a reel-bearing app.
    @Volatile private var foregroundPkg: String? = null
    private val consciousTick = object : Runnable {
        override fun run() {
            accountConscious()
            consciousHandler.postDelayed(this, CONSCIOUS_TICK_MS)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        store = ConfigStore(this)
        store.serviceEverConnected = true
        reload()
        startAsForeground()
        // Arm the protection watchdog (idempotent): once the user had a live
        // service, a later silent death gets detected and surfaced. Connecting
        // IS the recovery — clear any standing "Protection stopped" alert now
        // rather than waiting for the next 15-min check.
        WatchdogJobService.schedule(this)
        WatchdogJobService.clearAlert(this, store)
        ServiceEventBus.post("serviceStatus", mapOf("running" to true))
        Log.i(TAG, "service connected")
    }

    /** Reload config + settings (called after Dart pushes changes). */
    fun reload() {
        config = DetectionConfig.parse(store.platformsConfigJson)
        protectedPkgs = store.protectedPackages
        blockedApps = store.blockedAppPackages
        homePkgs = homePackages()
        masterOn = store.masterEnabled
        pausedUntil = store.pauseUntil
        activePlan = store.activePlan
        enabledPlatformIds = store.enabledPlatforms
        // Settle any accrued-but-unwritten bank before re-reading, so a config
        // push mid-tick can't roll the cache back to a stale stored value.
        flushConsciousBank(force = true)
        consciousBank = store.consciousBankMs
        webEngine.setBlocklist(store.webBlocklistJson)
        webEngine.setAdultEnabled(store.blockAdultWebsites)
        syncConscious()
        syncReelBubble()
    }

    private fun homePackages(): Set<String> = try {
        @Suppress("DEPRECATION")
        packageManager.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
            PackageManager.MATCH_DEFAULT_ONLY,
        ).mapNotNull { it.activityInfo?.packageName }.toSet()
    } catch (_: Throwable) {
        emptySet()
    }

    /**
     * Push the One Reel / Unblock "reels left" count to the bubble (null = normal
     * today total). Called on every config reload — so it arms on session start,
     * and clears back to the total when the mode reverts to Block All / Conscious.
     */
    private fun syncReelBubble() {
        contentCounter.setReelSessionRemaining(
            if (activePlan == PLAN_ONE_REEL) {
                (store.reelAllowance - store.reelsConsumed).coerceAtLeast(0)
            } else {
                null
            },
        )
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return

        matchMemo.clear()
        val pkgProtected = isProtected(pkg)

        // Track the foreground app for the Conscious accountant (every package,
        // including ours). Leaving a reel-bearing app for one without reel
        // surfaces immediately ends "watching" so the bank can start earning.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            foregroundPkg = pkg
            // A protected app counts as "no reel surfaces" even if it is also in
            // the monitored catalog — protection wins, and the stale "watching"
            // window dies the instant a protected app foregrounds.
            if (pkgProtected || config.platformsFor(pkg).isEmpty()) {
                lastReelAtMs = 0L
                reelViewStartMs = 0L // left the reel app → next reel is a fresh view
            }
            if (contentCounter.isEnabled) {
                contentCounter.onForegroundChanged(
                    pkg,
                    !pkgProtected && config.platformsFor(pkg).any { isReelPlatform(it) },
                )
            }
            // Privacy: drop the usage window so time inside the protected app
            // can never be attributed to the previously-foreground reel app.
            if (pkgProtected) contentCounter.onProtectedForeground()
        }

        // ── Privacy guard: the single decision point. Checks the event source
        // AND the focused window (split-screen: rootInActiveWindow is the
        // FOCUSED pane, so an event from the other pane must never walk a
        // protected pane's tree). Everything below — counting, browser URL
        // reads, tree walks, blocking — is unreachable for a protected app. ──
        if (pkgProtected || isProtected(foregroundPkg)) return

        if (pkg == packageName) return

        // ── Awareness counting: runs independent of blocking (master-off /
        // paused / platform-disabled) and is strictly side-effect-free w.r.t.
        // the block path below — it never returns and never mutates block state. ──
        if (contentCounter.isEnabled) countContent(event, pkg)

        if (!masterOn) return

        // Custom whole-app block — checked ABOVE the pause gate: the App
        // Blocker UI presents locks as unconditional, so a Pause taken for
        // reels must not quietly unlock a fully-locked app. Anchored to
        // the FOREGROUND — a blocked app's non-foreground windows (PiP, its own
        // overlays) still emit content-changed events under its packageName,
        // and acting on those would HOME-bounce the user out of unrelated
        // apps. The foregroundPkg leg still bounces someone already inside
        // the app when the block lands; the debounce caps the rate.
        if (pkg in blockedApps &&
            (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                pkg == foregroundPkg)
        ) {
            onAppBlocked(pkg)
            return
        }

        // Plan gate: a live Pause window suspends reel/web blocking (whole-app
        // locks above stay enforced) until pauseUntil, after which the active
        // plan resumes. Gated purely on the clock so it works regardless of the
        // pushed plan name.
        if (System.currentTimeMillis() < pausedUntil) return

        // One Reel / Unblock: capture reel-advance scrolls BEFORE the throttle
        // below. A scroll swallowed by the 150 ms throttle would leave the next
        // reel looking like the same one and leak it past the allowance.
        if (activePlan == PLAN_ONE_REEL &&
            event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED &&
            config.platformsFor(pkg).isNotEmpty()
        ) {
            lastScrollAtMs = System.currentTimeMillis()
        }

        // Per-package throttle.
        val now = System.currentTimeMillis()
        val last = lastEventByPackage[pkg] ?: 0L
        if (now - last < THROTTLE_MS) return
        lastEventByPackage[pkg] = now

        // Website blocking: only browsers reach this branch (a cheap set check),
        // and only on window/content changes, so non-browser apps pay nothing and
        // reel detection below is untouched. A browser carries no reel surfaces,
        // so we return either way.
        if (BrowserUrlExtractor.isBrowser(pkg)) {
            if (webEngine.hasAnyRules() &&
                (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                    event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            ) {
                handleBrowser(pkg)
            }
            return
        }

        val platforms = config.platformsFor(pkg)
        if (platforms.isEmpty()) return

        val enabled = enabledPlatformIds
        // Obtained roots are ours to recycle (a real leak below API 33).
        val root = rootInActiveWindow ?: return
        try {
            if (activeWindowProtected(root)) return

            for (platform in platforms) {
                if (platform.detectionType != "LEGACY" && platform.detectionType != "OVERLAY") continue
                // Respect user enable/disable; fall back to defaultStatus if unset.
                val isOn = if (enabled.isEmpty()) platform.defaultStatus
                else enabled.contains(platform.platformId)
                if (!isOn) continue

                for (detector in platform.detectors) {
                    if (detector.viewDetector != "FINDBYID" && detector.viewDetector != "VIEWID_RES_NAME") continue
                    if (matchesMemo(root, event, detector, pkg)) {
                        // Conscious mode: a reel is on screen. While there's allowance,
                        // mark "watching" (so the accountant drains the bank) and let
                        // it play. With an empty bank we leave "watching" untouched and
                        // fall through to block — so a bounced reel counts as
                        // abstaining and the bank starts refilling.
                        if (activePlan == PLAN_CONSCIOUS && consciousBank > 0L) {
                            lastReelAtMs = now
                            return
                        }
                        // One Reel / Unblock: allow while within the allowance, else
                        // fall through to block.
                        if (activePlan == PLAN_ONE_REEL && allowReelOrBlock(now)) {
                            return
                        }
                        onDetected(pkg, platform.platformId, detector)
                        if (detector.haltOnDetect) return
                    }
                }
            }
        } finally {
            root.recycleSafe()
        }
    }

    // ---- Detection (3-stage view-id search) --------------------------------

    /**
     * Per-event memoized [matches]: the counter and block passes share results.
     * ponytail: the memo is keyed by detector only, while each pass obtains its
     * own [rootInActiveWindow] — the block pass can reuse a result computed
     * against the counting pass's snapshot, microseconds stale. Accepted
     * ceiling; upgrade path = thread one root through both passes.
     */
    private fun matchesMemo(
        root: AccessibilityNodeInfo,
        event: AccessibilityEvent,
        detector: DetectorRule,
        pkg: String,
    ): Boolean = matchMemo.getOrPut(detector) { matches(root, event, detector, pkg) }

    private fun matches(
        root: AccessibilityNodeInfo,
        event: AccessibilityEvent,
        detector: DetectorRule,
        pkg: String,
    ): Boolean {
        // Fully-qualified target ids, built ONCE per call — stage 3 visits up
        // to MAX_NODES nodes, and a per-node "$pkg$id" concat was measurable
        // allocation churn on the hottest path.
        val targets = if (detector.viewDetector == "VIEWID_RES_NAME") {
            detector.identifiers
        } else {
            detector.identifiers.map { "$pkg$it" }
        }

        // Stage 1: the event source itself. (Every obtained node is recycled
        // before returning — matches() only ever answers a boolean.)
        val source = event.source
        if (source != null) {
            try {
                val sourceId = source.viewIdResourceName
                if (sourceId != null && sourceId in targets && source.isVisibleToUser) {
                    return true
                }
            } finally {
                source.recycleSafe()
            }
        }

        // Stage 2: direct resource-id lookup.
        for (target in targets) {
            val hits = root.findAccessibilityNodeInfosByViewId(target)
            if (!hits.isNullOrEmpty()) {
                var found = false
                for (n in hits) {
                    if (n == null) continue
                    if (!found && n.isVisibleToUser) found = true
                    n.recycleSafe()
                }
                if (found) return true
            }
        }

        // Stage 3: bounded DFS over the tree. The passed-in root is the caller's
        // to manage; every child obtained here is recycled exactly once.
        val deque = ArrayDeque<AccessibilityNodeInfo>()
        deque.addLast(root)
        var i = 0
        var found = false
        while (deque.isNotEmpty() && i < MAX_NODES && !found) {
            val node = deque.removeLast()
            i++
            val resName = node.viewIdResourceName
            if (resName != null && resName in targets && node.isVisibleToUser) {
                found = true
            }
            if (!found) {
                for (c in node.childCount - 1 downTo 0) {
                    node.getChild(c)?.let { deque.addLast(it) }
                }
            }
            if (node !== root) node.recycleSafe()
        }
        while (deque.isNotEmpty()) {
            val node = deque.removeLast()
            if (node !== root) node.recycleSafe()
        }
        return found
    }

    // ---- Awareness counting (independent of blocking) ----------------------

    /**
     * Side-effect-free counting pass. Forwards scrolls and reel-surface
     * detections to [contentCounter]; never presses back and never reads/writes
     * block state. Uses its own per-package throttle so the read-only [matches]
     * tree walk stays cheap even for apps not enabled for blocking.
     */
    private fun countContent(event: AccessibilityEvent, pkg: String) {
        val platforms = config.platformsFor(pkg)
        if (platforms.isEmpty()) return

        // Accrue whole-app foreground time for this monitored social app (feed /
        // stories / DMs / reels — broader than reel surfaces). Pure timestamp
        // math on every event; our own package is already excluded upstream.
        contentCounter.onAppActivity(pkg)

        // A scroll is the closest proxy to "advanced to the next reel" (cheap,
        // no tree walk); the counter debounces these itself.
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED) {
            contentCounter.onScroll(pkg)
        }

        // Throttle the (more expensive) surface detection per package.
        val now = System.currentTimeMillis()
        val last = lastCountEventByPackage[pkg] ?: 0L
        if (now - last < THROTTLE_MS) return
        lastCountEventByPackage[pkg] = now

        val root = rootInActiveWindow ?: return
        try {
            if (activeWindowProtected(root)) return
            for (platform in platforms) {
                if (!isReelPlatform(platform)) continue
                for (detector in platform.detectors) {
                    if (detector.viewDetector != "FINDBYID" &&
                        detector.viewDetector != "VIEWID_RES_NAME"
                    ) {
                        continue
                    }
                    if (matchesMemo(root, event, detector, pkg)) {
                        contentCounter.onReelSurfaceSeen(pkg)
                        return
                    }
                }
            }
            // We actively checked a reel app's window and found NO reel surface —
            // the user is on a non-reel screen (e.g. the feed). Distinct from "no
            // event" (passive watching), which never reaches here and keeps the
            // bubble up.
            contentCounter.onNoReelSurface(pkg)
        } finally {
            root.recycleSafe()
        }
    }

    /** A detectable reel/short surface (excludes feed / stories / status surfaces). */
    private fun isReelPlatform(p: PlatformRule): Boolean {
        if (p.detectionType != "LEGACY" && p.detectionType != "OVERLAY") return false
        if (p.platformId in NON_REEL_PLATFORM_IDS) return false
        return p.detectors.any {
            it.viewDetector == "FINDBYID" || it.viewDetector == "VIEWID_RES_NAME"
        }
    }

    // ---- Website blocking --------------------------------------------------

    /**
     * Reads the browser's address bar, and if the host is blocked, presses back
     * and reports it. Debounced per-host so a content-change storm on the same
     * blocked page produces at most one back press per window.
     */
    private fun handleBrowser(pkg: String) {
        val root = rootInActiveWindow ?: return
        val host: String
        try {
            if (activeWindowProtected(root)) return
            // Split-screen: rootInActiveWindow is the FOCUSED pane. An event from
            // an unfocused browser must not walk the other app's tree — the
            // generic fallback would harvest any url-ish EditText there and
            // BACK out of an unrelated app.
            if (root.packageName?.toString() != pkg) return
            host = BrowserUrlExtractor.extractHost(root, pkg, MAX_NODES) ?: return
        } finally {
            root.recycleSafe()
        }
        val match = webEngine.matchHost(host)
        if (match == null) {
            lastUrlByPkg[pkg] = host
            return
        }
        val now = System.currentTimeMillis()
        val sameAsLast = host == lastUrlByPkg[pkg]
        if (sameAsLast && now - lastWebBlockTime <= BLOCK_DEBOUNCE_MS) return
        lastUrlByPkg[pkg] = host
        lastWebBlockTime = now

        store.recordWebBlock(dateKey())
        val (today, total) = store.webBlockStats(dateKey())
        // EVO-018: adult-list hits are counted but never named — the host is
        // left out of the event (Dart's per-host tally / "Most blocked" skip it)
        // and out of the toast. User-rule hits stay attributable.
        val adult = match == WebBlockEngine.Match.ADULT
        val payload = HashMap<String, Any?>(6)
        payload["source"] = if (adult) "ADULT" else "RULE"
        payload["mode"] = "PRESS_BACK"
        payload["today"] = today
        payload["total"] = total
        if (!adult) payload["host"] = host
        ServiceEventBus.post("webBlocked", payload)
        // Never log the host: it's accessibility-derived browsing data and
        // release logcat is readable by adb / OEM log collectors.
        Log.i(TAG, "web-blocked in $pkg")
        // EVO-011: make the intervention legible — attribute the bounce.
        // ponytail: plain text toast; upgrade path is an overlay block chip.
        Toast.makeText(
            this,
            if (adult) getString(R.string.toast_blocked_adult) else getString(R.string.toast_blocked, host),
            Toast.LENGTH_SHORT,
        ).show()
        pressBackWithRateLimit()
    }

    // ---- Block execution ---------------------------------------------------

    private fun onDetected(pkg: String, platformId: String, detector: DetectorRule) {
        val now = System.currentTimeMillis()
        if (now - lastBlockTime <= BLOCK_DEBOUNCE_MS) return
        lastBlockTime = now

        val mode = resolveBlockMode(detector)
        store.recordBlock(dateKey())
        val (today, total, _) = store.blockStats(dateKey())
        ServiceEventBus.post(
            "blocked",
            mapOf("package" to pkg, "platformId" to platformId, "mode" to mode,
                "today" to today, "total" to total),
        )
        Log.i(TAG, "blocked $platformId in $pkg via $mode")

        when (mode) {
            "KILL_APP" -> { blockVibrate(); performBackInternal(); killApp(pkg) }
            "LOCK_SCREEN" -> { blockVibrate(); performBackInternal(); lockScreen() }
            "NONE" -> { /* no-op */ }
            else -> pressBackWithRateLimit()
        }
    }

    private fun resolveBlockMode(detector: DetectorRule): String {
        val def = store.defaultBlockMode
        val supported = detector.supportedBlockModes
        if (def != "NONE" && (supported.isEmpty() || supported.contains(def))) return def
        val firstSupported = supported.firstOrNull { it != "NONE" }
        return firstSupported ?: detector.defaultBlockMode.ifBlank { "PRESS_BACK" }
    }

    private fun pressBackWithRateLimit() {
        val now = System.currentTimeMillis()
        if (now - lastBackTime <= BACK_RATE_LIMIT_MS) return
        lastBackTime = now
        performBackInternal()
        blockVibrate()
    }

    /** [activeWindowProtected] on a freshly-obtained root, recycled before returning. */
    private fun activeWindowProtectedNow(): Boolean {
        val root = rootInActiveWindow ?: return false
        try {
            return activeWindowProtected(root)
        } finally {
            root.recycleSafe()
        }
    }

    private fun performBackInternal() {
        // Fail-closed: never BACK into a protected app (covers Dart-invoked
        // backs and any timer that fires after a switch into one). The active
        // window is the second anchor: foregroundPkg alone can be stale or
        // clobbered by an IME window during e.g. UPI PIN entry.
        if (isProtected(foregroundPkg)) return
        if (activeWindowProtectedNow()) return
        performGlobalAction(GLOBAL_ACTION_BACK)
    }

    fun performBackPublic() = performBackInternal()

    fun killApp(pkg: String) {
        if (isProtected(pkg)) return // never kill a protected app
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            am.killBackgroundProcesses(pkg)
        } catch (t: Throwable) {
            Log.w(TAG, "killApp failed: ${t.message}")
        }
    }

    fun lockScreen() {
        // Never lock mid-payment; window anchor covers a clobbered foregroundPkg.
        if (isProtected(foregroundPkg)) return
        if (activeWindowProtectedNow()) return
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val admin = ComponentName(this, DetoxoDeviceAdminReceiver::class.java)
            if (dpm.isAdminActive(admin)) dpm.lockNow()
        } catch (t: Throwable) {
            Log.w(TAG, "lockScreen failed: ${t.message}")
        }
    }

    /** Vibrate for a block, honoring the user's haptics setting. */
    private fun blockVibrate() {
        if (store.vibrationEnabled) vibrate()
    }

    private fun vibrate() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            // Firm, clearly-felt block buzz. On devices without amplitude control
            // the 255 is ignored and it plays at default strength.
            vibrator.vibrate(VibrationEffect.createOneShot(BLOCK_VIBRATION_MS, 255))
        } catch (_: Throwable) {
        }
    }

    private fun dateKey(): String = DateKeys.today()

    // ---- Custom whole-app blocks -------------------------------------------

    /** Bounce a custom-blocked app HOME (BACK would just navigate within it). */
    private fun onAppBlocked(pkg: String) {
        // Belt-and-braces: Dart filters these, but a stale push must never
        // bounce the launcher, system UI, Detoxo itself, or a protected app.
        if (isProtected(pkg) || pkg == packageName || pkg in homePkgs ||
            pkg == "com.android.systemui"
        ) {
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastAppBlockTime <= BLOCK_DEBOUNCE_MS) return
        lastAppBlockTime = now

        store.recordBlock(dateKey())
        val (today, total, _) = store.blockStats(dateKey())
        ServiceEventBus.post(
            "blocked",
            mapOf(
                "package" to pkg, "platformId" to "app_block", "mode" to "HOME",
                "today" to today, "total" to total,
            ),
        )
        Log.i(TAG, "blocked app_block in $pkg via HOME")
        val label = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(pkg, 0),
            ).toString()
        } catch (_: Throwable) {
            pkg
        }
        Toast.makeText(this, getString(R.string.toast_blocked, label), Toast.LENGTH_SHORT).show()
        blockVibrate()
        performGlobalAction(GLOBAL_ACTION_HOME)
    }

    // ---- Conscious accountant ----------------------------------------------

    /** Start/stop the 1 Hz Conscious accountant to match the active plan. */
    private fun syncConscious() {
        val conscious = activePlan == PLAN_CONSCIOUS
        when {
            conscious && !consciousRunning -> {
                consciousRunning = true
                // Anchor to now so we don't retroactively credit service downtime
                // (the persisted bank carries over; the elapsed clock restarts).
                consciousAnchorMs = System.currentTimeMillis()
                lastReelAtMs = 0L
                consciousHandler.removeCallbacks(consciousTick)
                consciousHandler.postDelayed(consciousTick, CONSCIOUS_TICK_MS)
                emitConsciousState()
            }
            !conscious && consciousRunning -> {
                consciousRunning = false
                consciousHandler.removeCallbacks(consciousTick)
                flushConsciousBank(force = true) // leaving the plan settles the bank
            }
            conscious -> emitConsciousState() // already running; refresh the UI
        }
    }

    /**
     * Explicit fresh-start reset (CommandHandler already zeroed the store):
     * drop the cache and any pending unflushed accrual, then reload.
     */
    fun onConsciousBankReset() {
        consciousBank = 0L
        consciousDirty = false
        reload()
    }

    /** Writes the cached bank through to prefs — at most once per flush window. */
    private fun flushConsciousBank(force: Boolean = false) {
        if (!consciousDirty) return
        val now = System.currentTimeMillis()
        if (!force && now - lastConsciousFlushMs < CONSCIOUS_FLUSH_MS) return
        store.consciousBankMs = consciousBank
        consciousDirty = false
        lastConsciousFlushMs = now
    }

    /** One accounting step: drain while watching, accrue while abstaining. */
    private fun accountConscious() {
        if (activePlan != PLAN_CONSCIOUS) return
        // Daily fresh start: the bank is re-earned each day — an overnight
        // abstain must not stockpile a free morning allowance.
        val today = dateKey()
        if (store.consciousDate != today) {
            store.consciousDate = today
            if (consciousBank > 0L) {
                consciousBank = 0L
                consciousDirty = true
                // Forced: consciousDate was just written durably, and a hard
                // kill before a throttled flush would leave date=today with
                // yesterday's bank — resurrecting a full day-stale allowance.
                flushConsciousBank(force = true)
            }
        }
        val now = System.currentTimeMillis()
        val anchor = consciousAnchorMs.let { if (it <= 0L) now else it }
        val elapsed = (now - anchor).coerceAtLeast(0L)
        consciousAnchorMs = now // advance first, even when we freeze below

        // Master protection off → freeze the bank: neither drain nor accrue. The
        // anchor is already advanced so re-enabling doesn't dump a huge credit.
        if (!masterOn) {
            flushConsciousBank()
            emitConsciousState()
            return
        }

        // Inside a Pause window (Conscious is the base mode being paused): every
        // reel is allowed and the reel gate is off, so freeze the bank rather
        // than silently accrue free allowance while the user scrolls unblocked.
        if (now < pausedUntil) {
            flushConsciousBank()
            emitConsciousState()
            return
        }

        // Protected app foreground: freeze the bank and drop any stale
        // "watching" so this 1 Hz timer can never BACK-press into it (the
        // WATCH_STALE_MS window would otherwise survive a reel→bank switch).
        if (isProtected(foregroundPkg)) {
            lastReelAtMs = 0L
            flushConsciousBank()
            emitConsciousState()
            return
        }

        // "Watching": a reel was detected very recently. "In a reel app": the
        // foreground app has reel surfaces but detection has gone quiet (a paused
        // video / a non-feed overlay). We only accrue when genuinely off reels,
        // so a paused reel can never refill the bank (and never drains for free).
        val watching = (now - lastReelAtMs) < WATCH_STALE_MS
        val inReelApp = foregroundPkg?.let { config.platformsFor(it).isNotEmpty() } ?: false
        var bank = consciousBank
        if (watching) {
            bank -= elapsed.coerceAtMost(CONSCIOUS_MAX_STEP_MS)
            if (bank <= 0L) {
                bank = 0L
                lastReelAtMs = 0L
                pressBackWithRateLimit() // allowance spent → boot the reel
            }
        } else if (!inReelApp) {
            bank = (bank + elapsed / store.consciousEarnDivisor)
                .coerceAtMost(store.consciousMaxBankMs)
        }
        // else: lingering on a reel app with no fresh detection → hold steady.
        if (bank < 0L) bank = 0L
        if (bank != consciousBank) {
            consciousBank = bank
            consciousDirty = true
        }
        // The empty-bank boundary is durability-critical (it is what keeps a
        // service restart blocked), so it flushes immediately.
        flushConsciousBank(force = bank == 0L)
        emitConsciousState(bank = bank, watching = watching)
    }

    private fun emitConsciousState(
        bank: Long = consciousBank,
        watching: Boolean = (System.currentTimeMillis() - lastReelAtMs) < WATCH_STALE_MS,
    ) {
        ServiceEventBus.post("consciousState", consciousSnapshot(bank, watching))
    }

    /** Current Conscious bank state (also used for the pull query). */
    fun consciousSnapshot(
        bank: Long = consciousBank,
        watching: Boolean = (System.currentTimeMillis() - lastReelAtMs) < WATCH_STALE_MS,
    ): Map<String, Any?> {
        val active = activePlan == PLAN_CONSCIOUS
        return mapOf(
            "bankMs" to bank,
            "maxBankMs" to store.consciousMaxBankMs,
            "watching" to (active && watching),
            "blocked" to (active && bank <= 0L),
            "active" to active,
        )
    }

    // ---- One Reel / Unblock (allow N reels, then block) --------------------

    /**
     * Gate for One Reel / Unblock: a reel surface is on screen — decide allow vs
     * block. Returns true to allow (caller returns), false to block (caller falls
     * through to [onDetected]).
     *
     * A reel costs ONE count, and only after it's been watched for [MIN_VIEW_MS]
     * (2s) — so a quick flick-through and a single looping reel each cost at most
     * one. Reels are delimited by scrolls (consecutive reels share the same
     * continuously-visible view-id, so a scroll is the "moved to the next reel"
     * signal), but a scroll only counts as an advance once ≥ 2s have passed since
     * the last count — this debounces in-reel scrolls (opening comments/captions)
     * so they don't burn the allowance or block the reel you're still watching.
     * The currently-playing reel is NEVER blocked; only a fresh reel that appears
     * after the allowance is spent is blocked (which drives the Dart auto-revert).
     *
     * ponytail: reel identity is heuristic (scroll + 2s dwell, no per-reel id). A
     * spurious scroll > 2s after a count can still be misread as an advance, and a
     * fast scroll within 2s of a count is absorbed into the current reel (a small
     * leniency). Upgrade path = content-based reel identity.
     */
    private fun allowReelOrBlock(now: Long): Boolean {
        // A fresh reel view: session/app start, or a real scroll-advance (≥ 2s
        // since the last count, so an in-reel scroll isn't read as moving on).
        val advanced = reelViewStartMs == 0L ||
            (lastScrollAtMs > reelViewStartMs && now - lastReelCountMs >= MIN_VIEW_MS)

        if (advanced) {
            // Count the reel we're leaving if it was actually watched (≥ 2s) and
            // not already counted — covers a passively-watched reel whose surface
            // stopped emitting events before its 2s same-reel tick fired.
            if (reelViewStartMs != 0L && !reelViewCounted &&
                now - reelViewStartMs >= MIN_VIEW_MS
            ) {
                countReel(now)
            }
            reelViewStartMs = now
            reelViewCounted = false
            if (store.reelsConsumed >= store.reelAllowance) {
                emitReelSessionState(blocked = true) // spent → block + Dart revert
                return false
            }
            emitReelSessionState(blocked = false)
            syncReelBubble()
            return true
        }

        // Same reel continuing: count it once it crosses the 2s dwell; the reel
        // being watched is never blocked, so always allow.
        if (!reelViewCounted && now - reelViewStartMs >= MIN_VIEW_MS) {
            countReel(now)
        }
        return true
    }

    /** Tally one watched reel toward the allowance and refresh the UI + bubble. */
    private fun countReel(now: Long) {
        store.reelsConsumed += 1
        reelViewCounted = true
        lastReelCountMs = now
        emitReelSessionState(blocked = false)
        syncReelBubble()
    }

    /** Re-arm a fresh reel session: zero the dwell state, reload, emit. */
    fun armReelSession() {
        reelViewStartMs = 0L
        reelViewCounted = false
        lastReelCountMs = 0L
        lastScrollAtMs = 0L
        reload()
        emitReelSessionState(blocked = false)
    }

    private fun emitReelSessionState(blocked: Boolean) {
        ServiceEventBus.post("reelSessionState", reelSessionSnapshot(blocked))
    }

    /**
     * Current One Reel / Unblock session state (also used for the pull query).
     * [blocked] is explicit on the live push paths; the pull query defaults it to
     * "allowance fully consumed" as a reasonable at-rest approximation.
     */
    fun reelSessionSnapshot(
        blocked: Boolean = activePlan == PLAN_ONE_REEL &&
            store.reelsConsumed >= store.reelAllowance,
    ): Map<String, Any?> {
        val active = activePlan == PLAN_ONE_REEL
        return mapOf(
            "consumed" to store.reelsConsumed,
            "allowance" to store.reelAllowance,
            "blocked" to blocked,
            "active" to active,
        )
    }

    // ---- Foreground service + lifecycle ------------------------------------

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.fgs_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                description = getString(R.string.fgs_channel_description)
            }
            nm.createNotificationChannel(channel)
        }
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.fgs_title))
            .setContentText(getString(R.string.fgs_text))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIF_ID, notification)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "startForeground failed: ${t.message}")
        }
    }

    override fun onInterrupt() {
        ServiceEventBus.post("serviceStatus", mapOf("running" to false))
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        consciousRunning = false
        consciousHandler.removeCallbacks(consciousTick)
        flushConsciousBank(force = true)
        runCatching { contentCounter.dispose() }
        ServiceEventBus.post("serviceStatus", mapOf("running" to false))
        return super.onUnbind(intent)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Keep the foreground service alive when the app is swiped away.
        try {
            startAsForeground()
        } catch (_: Throwable) {
        }
    }

    override fun onDestroy() {
        instance = null
        consciousRunning = false
        consciousHandler.removeCallbacks(consciousTick)
        flushConsciousBank(force = true)
        runCatching { contentCounter.dispose() }
        super.onDestroy()
    }

    companion object {
        private const val TAG = "DetoxoService"
        private const val CHANNEL_ID = "detoxo_protection_channel"
        private const val NOTIF_ID = 1125
        private const val THROTTLE_MS = 150L
        private const val BLOCK_DEBOUNCE_MS = 1200L
        private const val BACK_RATE_LIMIT_MS = 1100L
        private const val MAX_NODES = 12000

        /** Firm single block buzz — longer/stronger than a stray system tap. */
        private const val BLOCK_VIBRATION_MS = 60L

        /**
         * A reel must be watched this long (2s) to count toward the One Reel /
         * Unblock allowance — matching the awareness counter's dwell so a quick
         * flick-through or a single looping reel costs at most one count.
         */
        private const val MIN_VIEW_MS = 2000L

        /** Active-plan token for Conscious (shares the legacy "CURIOUS" wire). */
        private const val PLAN_CONSCIOUS = "CURIOUS"

        /** Active-plan token for One Reel / Unblock (allow N reels, then block). */
        private const val PLAN_ONE_REEL = "ONE_REEL"

        /** Conscious accountant cadence. */
        private const val CONSCIOUS_TICK_MS = 1000L

        /** Batch Conscious-bank prefs writes to at most one per this interval. */
        private const val CONSCIOUS_FLUSH_MS = 5000L

        /** A reel detected within this window counts as "still watching". */
        private const val WATCH_STALE_MS = 2500L

        /** Cap a single drain step so a delayed tick can't dump the whole bank. */
        private const val CONSCIOUS_MAX_STEP_MS = 5000L

        /**
         * Non-reel surfaces inside supported apps that must NOT be counted as
         * short videos (feeds, stories, statuses). Everything else detectable in
         * a supported app is treated as a reel/short.
         */
        private val NON_REEL_PLATFORM_IDS = setOf(
            "ig_feed", "ig_stories", "insta_pro_stories", "insta_pro2_stories",
            "snap_stories", "wa_status", "wab_status",
        )

        @Volatile
        var instance: DetoxoAccessibilityService? = null
            private set

        fun isRunning(): Boolean = instance != null
    }
}
