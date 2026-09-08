package com.errorxperts.detoxo.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.errorxperts.detoxo.R
import com.errorxperts.detoxo.admin.DetoxoDeviceAdminReceiver
import com.errorxperts.detoxo.engine.BrowserUrlExtractor
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ContentCounter
import com.errorxperts.detoxo.engine.DateKeys
import com.errorxperts.detoxo.engine.DetectionConfig
import com.errorxperts.detoxo.engine.DetectorRule
import com.errorxperts.detoxo.engine.NudgeDecision
import com.errorxperts.detoxo.engine.NudgeTracker
import com.errorxperts.detoxo.engine.PlatformRule
import com.errorxperts.detoxo.engine.ReelTracker
import com.errorxperts.detoxo.engine.LimitReconciler
import com.errorxperts.detoxo.engine.RuleEngine
import com.errorxperts.detoxo.engine.ServiceEventBus
import com.errorxperts.detoxo.engine.SuppressionDecision
import com.errorxperts.detoxo.engine.UnblockRegistry
import com.errorxperts.detoxo.engine.WebBlockEngine
import com.errorxperts.detoxo.engine.recycleSafe
import com.errorxperts.detoxo.overlay.BlockScreenOverlay
import com.errorxperts.detoxo.overlay.BlockScreenPayload
import com.errorxperts.detoxo.overlay.NudgeOverlay
import com.errorxperts.detoxo.overlay.WallPolicy
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
        // The nudge's watch list is derived by subtracting this set, so it has
        // to be recomputed here too — protecting an app must take the nudge off
        // it immediately, not at the next unrelated settings push.
        refreshNudgeConfig()
    }

    /**
     * Whether [pkg]'s notifications may be cancelled right now — the single
     * question `DetoxoNotificationListener` asks, on a callback that fires for
     * every notification on the device.
     *
     * Reads only the @Volatile mirrors above and the in-memory [ruleEngine]:
     * no SharedPreferences, no Dart round-trip, no allocation. The decision
     * itself lives in [SuppressionDecision], which is Android-free so it can be
     * unit-tested — this service cannot.
     */
    fun shouldSuppressNotification(pkg: String): Boolean {
        if (!suppressNotifications || !masterOn) return false
        val now = System.currentTimeMillis()
        return SuppressionDecision.shouldSuppress(
            pkg = pkg,
            ownPkg = packageName,
            protectedPkgs = protectedPkgs,
            blockedApps = blockedApps,
            rules = ruleEngine,
            now = now,
            paused = now < pausedUntil,
        )
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

    // ── Block screen (intervention wall) ─────────────────────────────────────
    /**
     * Packages of the enabled accessibility services (TalkBack, Switch Access…).
     * Their menus foreground under their own package; a standing block screen
     * must not read that as "the user left". Refreshed by [reload].
     */
    @Volatile private var a11yPkgs: Set<String> = emptySet()

    /**
     * The package that was in front before the current one — where the
     * engine's BACK may land (a reel opened from a share link returns to the
     * sharing app). A reel / website wall stays over it (EVO-026).
     */
    @Volatile private var prevForegroundPkg: String? = null

    /**
     * Screen-off takes a standing wall — and a standing nudge card — down. The
     * MainActivity receiver cannot do it: it lives with the UI, which is dead
     * exactly when the wall is up.
     */
    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            BlockScreenOverlay.hide()
            NudgeOverlay.hide()
        }
    }
    private var screenOffRegistered = false

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

    /**
     * Cheap refresh for pushTemporaryUnblocks (M8). Also called from [reload],
     * so a reboot or a service reconnect re-anchors every grant's monotonic
     * deadline against the surviving wall stamp — without that second caller
     * every grant would silently die at reboot.
     */
    fun refreshTemporaryUnblocks() {
        unblocks.setGrants(
            store.temporaryUnblocksJson,
            System.currentTimeMillis(),
            SystemClock.elapsedRealtime(),
        )
    }

    /**
     * M8: is [pkg] temporarily unblocked right now?
     *
     * One volatile read for the (overwhelmingly common) no-grants case, so the
     * elapsedRealtime call only happens for a user who actually holds a grant.
     * Consulted by the App Blocker arm and the NON-strict package rule arm —
     * never by the strict arm between them, and never before the cheaper guards
     * those arms already apply, so a grant-holder does not pay for it on every
     * event of every app.
     */
    private fun appUnblocked(pkg: String): Boolean {
        val nowE = SystemClock.elapsedRealtime()
        return unblocks.hasAny(UnblockRegistry.TYPE_APP, nowE) &&
            unblocks.isUnblocked(UnblockRegistry.TYPE_APP, pkg, nowE)
    }

    // ── Soft nudge ────────────────────────────────────────────────────────────
    /**
     * The advisory dwell nudge. Not a blocker: it never returns, never presses
     * BACK and never touches block state — it only reads the foreground package
     * off an event that has already been dispatched, so it adds nothing to the
     * tree walk. Rebuilt on each config push because its tuning is constructor
     * state; the live session is meant to die with it.
     */
    private val nudge = NudgeTracker()

    /**
     * The app the nudge considers foreground. [foregroundPkg] cannot be used
     * directly: it latches the IME's package when the soft keyboard opens, and
     * resolving the IME costs a binder read that the per-event nudge tick must
     * not pay. Latched here on window changes, where the answer is already
     * computed for the counter.
     */
    @Volatile private var nudgeForegroundPkg: String? = null

    /** Own throttle stamp for the nudge tick — see the call site. */
    private var lastNudgeTickMs = 0L

    /**
     * Cheap refresh for pushNudgeConfig (mirrors [refreshProtectedPackages]).
     *
     * Reconfigures the tracker **in place** — `pushSettings` lands here on
     * every resume and every settings write, and rebuilding it handed the user
     * a fresh daily budget each time (see [NudgeTracker.configure]).
     *
     * The protected subtraction is the nudge's second privacy anchor: even if
     * the foreground latch were wrong, a protected app cannot be in the set the
     * machine will act on. Also re-run from [refreshProtectedPackages] so the
     * two sets can never drift apart.
     */
    fun refreshNudgeConfig() {
        nudge.configure(
            enabled = store.nudgeEnabled,
            packages = store.nudgePackages - protectedPkgs,
            thresholdStepMs = store.nudgeStepMs,
            dailyCap = store.nudgeDailyCap,
        )
        if (!store.nudgeEnabled) NudgeOverlay.hide()
    }

    /** EVO-029: whether the watchdog has any rule budget worth re-measuring. */
    fun hasPendingRuleLimits(): Boolean = ruleEngine.hasPendingLimits()

    /** Which of the two UsageStats queries the pending budgets actually need. */
    fun hasPendingUsageLimits(): Boolean = ruleEngine.hasPendingUsageLimits()
    fun hasPendingOpenLimits(): Boolean = ruleEngine.hasPendingOpenLimits()

    /**
     * EVO-029: flip every pending rule limit whose budget today's measurements
     * say is used up. True when something actually changed, so the caller only
     * notifies Dart on a real flip.
     */
    fun markRuleLimitsSpent(
        usageMsByPackage: Map<String, Long>,
        opensByPackage: Map<String, Int>,
    ): Boolean = ruleEngine.markSpent(
        LimitReconciler.spentIds(ruleEngine.pendingLimits(), usageMsByPackage, opensByPackage),
    )

    /** Cheap refresh for pushRules: the snapshot + the boundary mirror only. */
    fun refreshRules() {
        ruleEngine.setSnapshot(store.rulesJson)
        nextBoundaryMs = store.nextBoundaryMs
    }

    /**
     * Posts `ruleBoundary` once the pushed boundary has passed — called on
     * every window-state change and from the watchdog tick — then clears it so
     * it fires once; Dart's re-push arms the next one. A dead Dart drops the
     * event; the next resume re-pushes regardless.
     */
    fun checkRuleBoundary(now: Long) {
        val boundary = nextBoundaryMs
        if (boundary <= 0L || now < boundary) return
        nextBoundaryMs = 0L
        store.nextBoundaryMs = 0L
        ServiceEventBus.post("ruleBoundary", mapOf("atMs" to boundary))
    }

    // ── Hot-path settings cache ──────────────────────────────────────────────
    // Mirrors of the per-event settings flags, same pattern as [protectedPkgs]:
    // the event path touches no SharedPreferences. Safe because every write
    // goes through CommandHandler, which always follows with reload().
    @Volatile private var masterOn = true
    @Volatile private var pausedUntil = 0L
    @Volatile private var activePlan = ""
    @Volatile private var enabledPlatformIds: Set<String> = emptySet()
    // Read on the notification listener's callback, not this service's event
    // path — same no-prefs-per-callback contract (see [shouldSuppressNotification]).
    @Volatile private var suppressNotifications = false

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
    // Consecutive counting-pass misses per package, cycling 0..DFS_SKIP: the
    // stage-3 DFS runs only at 0 (see countContent). Main thread only.
    private val countMisses = HashMap<String, Int>()
    // Scroll-field calibration log switch, read once per bind (a property
    // lookup per raw scroll event would otherwise sit on the pre-throttle path).
    private val scrollDebug = Log.isLoggable(TAG, Log.DEBUG)

    // ── Temporary unblocks (M8) ──────────────────────────────────────────────
    // Per-target grants ("Instagram for 15 minutes"): consulted at the App
    // Blocker arm, the non-strict rule arms, the reel loop and the web engine —
    // and DELIBERATELY NOT at the strict arm below. That absence is the whole
    // guarantee that a one-tap unblock cannot lift a rule the user marked
    // Strict (or Locked, which implies it); no wire flag can be forged into it.
    private val unblocks = UnblockRegistry()

    // ── Website blocking ──────────────────────────────────────────────────────
    private val webEngine by lazy { WebBlockEngine(this, unblocks) }
    // Last seen host per browser package — avoids re-pressing back on a host that
    // is still on screen while the back navigation settles.
    private val lastUrlByPkg = ConcurrentHashMap<String, String>()
    @Volatile private var lastWebBlockTime = 0L

    // ── Rules (schedules / daily limits) ──────────────────────────────────────
    // The snapshot Dart pushes via pushRules: flat targets + absolute windows,
    // held in memory by RuleEngine (never re-read from prefs per event).
    // Checked BELOW the pause gate by design — a Pause or emergency pass lifts
    // rules the way it lifts reel and web blocking; App Blocker locks above the
    // gate stay unconditional. `nextBoundaryMs` mirrors the prefs key so the
    // per-window-change boundary check is one long compare.
    private val ruleEngine by lazy { RuleEngine() }
    @Volatile private var nextBoundaryMs = 0L

    // ── Conscious (earn-as-you-abstain) ──────────────────────────────────────
    // A 1 Hz accountant runs while the active plan is Conscious so the bank keeps
    // ticking even when the Flutter UI is dead.
    private val consciousHandler = Handler(Looper.getMainLooper())
    private var consciousRunning = false
    @Volatile private var lastReelAtMs = 0L

    /**
     * The reel surface that last set [lastReelAtMs]. The drain-to-empty wall used
     * to name the foreground package's FIRST reel platform, which for a
     * multi-surface app is often not the one being watched — and since M8 that
     * `referenceId` is what an "Unblock for a while" tap grants, so the user
     * would have bought a grant for a surface they were not on. Cleared
     * wherever [lastReelAtMs] is.
     */
    @Volatile private var lastReelPlatformId = ""

    // ── One Reel / Unblock (allow N reels, then block) ───────────────────────
    // Runtime-only dwell state (meaningless across a service restart); the
    // consumed count is persisted in ConfigStore so a restart keeps the user
    // blocked until an explicit re-tap, and these self-correct from it.
    //  - `lastScrollAtMs`  : a reel-advance scroll (captured pre-throttle). Only
    //    a scroll whose settled pager page differs from `oneReelPage` stamps it
    //    (`ReelTracker.settledPage`), so mid-fling frames, comment-sheet and
    //    caption scrolls, and a snap-back onto the same reel never do.
    //  - `reelViewStartMs` : when the current reel view began (0 = none/fresh).
    //  - `reelViewCounted` : the current reel already cost one count (loop-safe).
    //  - `lastReelCountMs` : when the last reel was counted (second guard against
    //    an in-reel scroll being read as a reel advance).
    // A reel counts toward the allowance only after MIN_VIEW_MS (2s) of dwell, so
    // a quick flick-through or a single looping reel costs at most one count.
    @Volatile private var lastScrollAtMs = 0L
    @Volatile private var oneReelPage = ReelTracker.NO_INDEX
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
        if (!screenOffRegistered) {
            ContextCompat.registerReceiver(
                this,
                screenOffReceiver,
                IntentFilter(Intent.ACTION_SCREEN_OFF),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            screenOffRegistered = true
        }
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
        a11yPkgs = accessibilityPackages()
        masterOn = store.masterEnabled
        pausedUntil = store.pauseUntil
        activePlan = store.activePlan
        enabledPlatformIds = store.enabledPlatforms
        suppressNotifications = store.suppressNotifications
        // Settle any accrued-but-unwritten bank before re-reading, so a config
        // push mid-tick can't roll the cache back to a stale stored value.
        flushConsciousBank(force = true)
        consciousBank = store.consciousBankMs
        webEngine.setBlocklist(store.webBlocklistJson)
        webEngine.setAdultEnabled(store.blockAdultWebsites)
        refreshTemporaryUnblocks()
        refreshRules()
        refreshNudgeConfig()
        syncConscious()
        syncReelBubble()
        // A Pause or protection-off lifts every block, so a standing wall goes too.
        if (!masterOn || System.currentTimeMillis() < pausedUntil) BlockScreenOverlay.hide()
    }

    private fun accessibilityPackages(): Set<String> = try {
        val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .mapNotNull { it.resolveInfo?.serviceInfo?.packageName }
            .toSet()
    } catch (_: Throwable) {
        emptySet()
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
        // One clock read for the whole event: the boundary check, the pause
        // gate, the rules arm and the throttle below all used to take their own.
        val nowMs = System.currentTimeMillis()

        // Track the foreground app for the Conscious accountant (every package,
        // including ours). Leaving a reel-bearing app for one without reel
        // surfaces immediately ends "watching" so the bank can start earning.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            if (pkg != foregroundPkg) {
                prevForegroundPkg = foregroundPkg
                foregroundPkg = pkg
            }
            // A rule window may have opened or closed — one long compare.
            checkRuleBoundary(nowMs)
            // The soft keyboard's window carries the IME's package: to the wall,
            // the counter and the nudge that is not a foreground change (typing
            // a comment must not dismiss a wall, suspend the reel, or end a
            // stay). ONE resolve for all three — it is a binder read, and the
            // wall branch below used to make a second one of its own.
            val isIme = isImePackage(pkg)
            // A standing block screen comes down when the user actually leaves
            // the apps it was raised over — not for our own windows, system UI,
            // an accessibility service's menu, the IME, or the launcher / the
            // opening app a BACK or HOME just landed on (BlockScreenOverlay
            // .staysOver). Within that set the wall only learns the foreground
            // moved, so "Back to X" can become "Dismiss" once X is gone. The
            // isShowing() short-circuit keeps this free while no wall is up.
            if (BlockScreenOverlay.isShowing() &&
                pkg != packageName &&
                pkg != "com.android.systemui" &&
                pkg !in a11yPkgs &&
                !isIme
            ) {
                if (BlockScreenOverlay.staysOver(pkg)) {
                    BlockScreenOverlay.onForeground(pkg)
                } else {
                    BlockScreenOverlay.hide()
                }
            }
            // A protected app counts as "no reel surfaces" even if it is also in
            // the monitored catalog — protection wins, and the stale "watching"
            // window dies the instant a protected app foregrounds.
            if (pkgProtected || config.platformsFor(pkg).isEmpty()) {
                lastReelAtMs = 0L
                lastReelPlatformId = ""
                reelViewStartMs = 0L // left the reel app → next reel is a fresh view
                oneReelPage = ReelTracker.NO_INDEX
            }
            if (contentCounter.isEnabled && !isIme) {
                contentCounter.onForegroundChanged(
                    pkg,
                    !pkgProtected && config.platformsFor(pkg).any { isReelPlatform(it) },
                )
            }
            // A protected app is never a nudgeable foreground. This must be
            // latched here and not left to the privacy guard below: the guard
            // keys on `foregroundPkg`, which the IME's own window CLOBBERS
            // (see the KDoc on [activeWindowProtected]) — so a keystroke inside
            // a protected app arrives with the guard satisfied while this latch
            // still pointed at the protected package. Null, not "skip": the
            // stale value is exactly the thing that must not survive.
            if (!isIme) nudgeForegroundPkg = if (pkgProtected) null else pkg
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

        // ── Soft nudge: advisory, so like the counter it runs above the master
        // switch and the pause gate — the user asked to be told how long they
        // have been somewhere, which is true whether or not blocking is on. ──
        // Throttled on its own stamp — the map at the block throttle below is
        // keyed on the EVENT's package, and the nudge is driven by the latched
        // foreground one. The dense heartbeat the idle rule needs is dense
        // relative to IDLE_TIMEOUT_MS (60 s), so ~6.7 Hz still leaves a 400×
        // margin while cutting the per-event work inside a watched app.
        if (nudge.enabled && nowMs - lastNudgeTickMs >= THROTTLE_MS) {
            lastNudgeTickMs = nowMs
            tickNudge(nowMs)
        }

        if (!masterOn) return

        // Custom whole-app block — checked ABOVE the pause gate: a Pause taken
        // for reels must not quietly unlock a fully-locked app. A per-target
        // grant DOES lift it, and that is the point of M8: "Unblock Instagram
        // for 15 minutes" has to work from an app-block wall and from the
        // blocklist row, or the only way in is turning protection off entirely.
        // A Pause still does not. Anchored to the FOREGROUND — a blocked app's
        // non-foreground windows (PiP, its own overlays) still emit
        // content-changed events under its packageName, and acting on those
        // would HOME-bounce the user out of unrelated apps. The foregroundPkg
        // leg still bounces someone already inside the app when the block
        // lands; the debounce caps the rate.
        if (pkg in blockedApps &&
            (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                pkg == foregroundPkg) &&
            !appUnblocked(pkg)
        ) {
            // A grant lifts THIS arm, but never the strict arm below it. So if
            // a strict (or locked) rule covers the package too, the wall must
            // not offer relief it cannot deliver: the user would spend the tap,
            // get the grant, and be bounced by the very next event with no
            // button and no explanation. Resolved only on the block path, which
            // is already debounced.
            val strictToo = ruleEngine.hasStrictRules() &&
                ruleEngine.blockingForPackage(pkg, nowMs, strictOnly = true) != null
            onAppBlocked(pkg, offersUnblock = !strictToo)
            return
        }

        // Plan gate: a live Pause window suspends reel/web blocking (whole-app
        // locks above stay enforced) until pauseUntil, after which the active
        // plan resumes. Gated purely on the clock so it works regardless of the
        // pushed plan name.
        // EVO-030: strict rules run ABOVE the pause gate — the user opted them
        // in precisely so a Pause cannot lift them. Everything else about the
        // arm is identical to the one below; only the gate placement differs.
        //
        // M8: this arm deliberately does NOT read `appUnblocked`. A locked rule
        // is pushed as strict, so the only thing that lifts one is an override,
        // which Dart expresses by splitting that rule's own windows before the
        // push — never by minting a grant. `offersUnblock = false` on the wall
        // it raises, so the button is not even offered.
        if (ruleEngine.hasStrictPackageRules() &&
            (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                pkg == foregroundPkg)
        ) {
            val strict = ruleEngine.blockingForPackage(pkg, nowMs, strictOnly = true)
            if (strict != null) {
                onAppBlocked(pkg, strict.reason, strict.activeUntil(nowMs), offersUnblock = false)
                return
            }
        }

        // A Pause suspends reel/web blocking. It normally returns here — but a
        // STRICT rule has to survive it, and that decision is made further down:
        // for a reel surface inside the detector loop, for a website inside the
        // browser arm. Either one has to be allowed to run, so this gate opens
        // for both; `paused` then narrows each pass to strict entries only.
        //
        // Both legs are load-bearing. Gating on platforms alone silently voided
        // the host half: a locked rule built from websites or a category carries
        // no platformIds (a category flattens to packages + domains), so it
        // returned here and its sites were free for the whole Pause — the exact
        // gap M8 exists to close.
        val paused = nowMs < pausedUntil
        if (paused &&
            !ruleEngine.hasStrictPlatformRules() &&
            !ruleEngine.hasStrictHostRules()
        ) {
            return
        }

        // Rules: a schedule window or a spent daily limit covering this app
        // (the pushRules snapshot). Below the pause gate by design — see the
        // ruleEngine field. Foreground-anchored like the App Blocker arm above,
        // and before the throttle so a WINDOW_STATE_CHANGED is never swallowed.
        // Gated on hasPackageRules, NOT hasAnyRules: a user with only a global
        // Daily Limit has a (meter) entry and no package rule at all, and this
        // arm runs above the throttle on essentially every foreground event.
        if (!paused && ruleEngine.hasPackageRules() &&
            (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                pkg == foregroundPkg) &&
            !appUnblocked(pkg)
        ) {
            val rule = ruleEngine.blockingForPackage(pkg, nowMs)
            if (rule != null) {
                onAppBlocked(pkg, rule.reason, rule.activeUntil(nowMs))
                return
            }
        }

        // One Reel / Unblock: capture reel-advance scrolls BEFORE the throttle
        // below. A scroll swallowed by the 150 ms throttle would leave the next
        // reel looking like the same one and leak it past the allowance. Only a
        // scroll that lands on a different pager page is an advance; a
        // multi-item list (comments) never is, an unindexed view always is.
        // `!paused` for the same reason as the browser branch: a Pause never
        // used to reach this, and a strict reel rule must not start consuming
        // One Reel allowance while blocking is suspended.
        if (!paused &&
            activePlan == PLAN_ONE_REEL &&
            event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED &&
            config.platformsFor(pkg).isNotEmpty()
        ) {
            val page = ReelTracker.settledPage(event.fromIndex, event.toIndex)
            if (page != ReelTracker.IGNORE &&
                (page == ReelTracker.NO_INDEX || page != oneReelPage)
            ) {
                lastScrollAtMs = System.currentTimeMillis()
                oneReelPage = page
            }
        }

        // Per-package throttle.
        val now = nowMs
        val last = lastEventByPackage[pkg] ?: 0L
        if (now - last < THROTTLE_MS) return
        lastEventByPackage[pkg] = now

        // Website blocking: only browsers reach this branch (a cheap set check),
        // and only on window/content changes, so non-browser apps pay nothing and
        // reel detection below is untouched. A browser carries no reel surfaces,
        // so we return either way.
        if (BrowserUrlExtractor.isBrowser(pkg)) {
            // A Pause still lifts the user's own website blocklist and every
            // non-strict host rule — its shipped meaning, unchanged.
            //
            // M8 closes EVO-030's documented scope gap: a STRICT host rule now
            // survives a Pause, exactly like the reel loop below. Without this a
            // locked rule (which is pushed as strict) would cost an override on
            // its apps and reel feeds while a 2-minute Pause opened its websites
            // for free — and `strictOnly = paused` inside `handleBrowser`
            // narrows the pass to opted-in entries, so nothing else changes.
            if ((!paused || ruleEngine.hasStrictHostRules()) &&
                (webEngine.hasAnyRules() || ruleEngine.hasHostRules()) &&
                (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
                    event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            ) {
                handleBrowser(pkg, paused)
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

            // 0 when no REEL grant is live, which the loop reads as "check
            // nothing" — one clock read for the whole pass either way.
            val nowElapsed = SystemClock.elapsedRealtime().let {
                if (unblocks.hasAny(UnblockRegistry.TYPE_REEL, it)) it else 0L
            }

            for (platform in platforms) {
                if (platform.detectionType != "LEGACY" && platform.detectionType != "OVERLAY") continue
                // Respect user enable/disable; fall back to defaultStatus if unset.
                val isOn = if (enabled.isEmpty()) platform.defaultStatus
                else enabled.contains(platform.platformId)
                if (!isOn) continue
                // M8: is this reel surface temporarily unblocked? Resolved per
                // platform, consumed below — a grant lifts the plan and a
                // non-strict rule, never a strict (and therefore never a
                // locked) one. Counting is unaffected: the awareness pass ran
                // above this branch, so a granted reel is still counted.
                val reelUnblocked = nowElapsed != 0L &&
                    unblocks.isUnblocked(
                        UnblockRegistry.TYPE_REEL,
                        platform.platformId,
                        nowElapsed,
                    )

                for (detector in platform.detectors) {
                    if (detector.viewDetector != "FINDBYID" && detector.viewDetector != "VIEWID_RES_NAME") continue
                    if (matchesMemo(root, event, detector)) {
                        // The meter's prefs read happens only when a meter entry
                        // exists, and only here — after a match.
                        val meterMs =
                            if (ruleEngine.hasReelMeter()) contentCounter.timeTodayMs(now) else 0L
                        // STRICT FIRST, mirroring the package arm above the pause
                        // gate. `blockingForPlatform` returns the FIRST covering
                        // entry and the snapshot is ordered by `createdAtMs`, so
                        // an older non-strict rule would otherwise mask a newer
                        // strict — and therefore a LOCKED — one: its wall would
                        // offer "Unblock for a while", and the grant that tap
                        // mints would lift the locked rule for free. Resolving
                        // strict on its own pass makes the guarantee independent
                        // of the order the user happened to create rules in.
                        val strictRule = if (ruleEngine.hasStrictPlatformRules()) {
                            ruleEngine.blockingForPlatform(
                                platform.platformId,
                                now,
                                meterMs,
                                strictOnly = true,
                            )
                        } else {
                            null
                        }
                        if (strictRule != null) {
                            onDetected(
                                pkg,
                                platform.platformId,
                                detector,
                                ruleReason = strictRule.reason,
                                ruleUnlocksAtMs = strictRule.activeUntil(now),
                                // A grant can never lift this, so never offer one.
                                offersUnblock = false,
                            )
                            if (detector.haltOnDetect) return
                            continue
                        }
                        // Everything below here is lifted by a Pause. We are past
                        // the gate solely to give a strict rule its chance above;
                        // nothing below — a non-strict rule, Conscious, One Reel,
                        // the plan — may fire, or a Pause would stop lifting reel
                        // blocking. `continue`, not `return`: another platform may
                        // carry the strict rule this one lacks.
                        if (paused) continue
                        // A non-strict schedule window or the spent daily reel
                        // limit blocks this surface whatever the plan below would
                        // allow — unless a grant lifts it, which is exactly the
                        // set a Pause lifts too.
                        val rule = if (ruleEngine.hasPlatformRules()) {
                            ruleEngine.blockingForPlatform(platform.platformId, now, meterMs)
                        } else {
                            null
                        }
                        if (rule != null && !reelUnblocked) {
                            onDetected(
                                pkg,
                                platform.platformId,
                                detector,
                                ruleReason = rule.reason,
                                ruleUnlocksAtMs = rule.activeUntil(now),
                            )
                            if (detector.haltOnDetect) return
                            continue
                        }
                        // M8: nothing strict is blocking this surface and the
                        // plan below would. The grant lifts it — and clearing
                        // the watch stamp drops the accountant into its existing
                        // "lingering in a reel app" branch, which neither drains
                        // nor accrues, so a granted reel is free but not earning.
                        if (reelUnblocked) {
                            lastReelAtMs = 0L
                            lastReelPlatformId = ""
                            return
                        }
                        // Conscious mode: a reel is on screen. While there's allowance,
                        // mark "watching" (so the accountant drains the bank) and let
                        // it play. With an empty bank we leave "watching" untouched and
                        // fall through to block — so a bounced reel counts as
                        // abstaining and the bank starts refilling.
                        if (activePlan == PLAN_CONSCIOUS && consciousBank > 0L) {
                            lastReelAtMs = now
                            lastReelPlatformId = platform.platformId
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
    ): Boolean = matchMemo.getOrPut(detector) { matches(root, event, detector) }

    /**
     * [deep] = false runs stages 1–2 only (the counting pass's DFS back-off,
     * EVO-021). Such a result is partial, so callers must NOT memoise it — a
     * negative could otherwise be reused by the block pass.
     */
    private fun matches(
        root: AccessibilityNodeInfo,
        event: AccessibilityEvent,
        detector: DetectorRule,
        deep: Boolean = true,
    ): Boolean {
        // Fully-qualified target ids, built once at config parse — stage 3
        // visits up to MAX_NODES nodes, and a per-node "$pkg$id" concat was
        // measurable allocation churn on the hottest path.
        val targets = detector.qualifiedIds

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

        if (!deep) return false

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

        // A scroll carries the pager's own visible-page range — the reel's
        // identity — for free (no tree walk); the counter settles + classifies
        // it. Forwarded pre-throttle: the last event of a fling is the one that
        // matters. `adb shell setprop log.tag.DetoxoService DEBUG` (then re-bind
        // the service) logs the raw fields for per-app calibration.
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED) {
            val deltaY = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) event.scrollDeltaY else 0
            val isPager = pagerVerdict(event, platforms)
            if (scrollDebug) {
                Log.d(
                    TAG,
                    "scroll $pkg from=${event.fromIndex} to=${event.toIndex} " +
                        "n=${event.itemCount} dy=$deltaY cls=${event.className} pager=$isPager",
                )
            }
            contentCounter.onScroll(pkg, event.fromIndex, event.toIndex, deltaY, isPager)
        }

        // Throttle the (more expensive) surface detection per package. Surface
        // presence changes on screen transitions, not per frame, so this pass
        // checks at a slower cadence than the block path — except a window
        // state change, which always checks (reel entry / exit latency).
        val now = System.currentTimeMillis()
        val last = lastCountEventByPackage[pkg] ?: 0L
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            now - last < COUNT_THROTTLE_MS
        ) {
            return
        }
        lastCountEventByPackage[pkg] = now

        // DFS back-off (EVO-021): on a non-reel screen (the feed) every check
        // used to end in a full stage-3 walk (≤ MAX_NODES binder reads) just to
        // learn "still no reel". After a miss, the next DFS_SKIP checks run
        // stages 1–2 only — stage 2 (findAccessibilityNodeInfosByViewId under
        // flagReportViewIds) resolves any real View by id, so a reel surface is
        // still seen at the 400 ms cadence. A window change always checks deep.
        // Shallow results bypass the memo (see matches), so the block pass —
        // which never backs off — still gets its full answer.
        // ponytail: a surface only the DFS finds (id not resolvable through the
        // app's own Resources, e.g. a split-module id) is seen ≤ DFS_SKIP checks
        // late (≤ 2 s), and a transient deep miss on it can end the reel session.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            countMisses.remove(pkg)
        }
        val misses = countMisses[pkg] ?: 0
        val deep = misses == 0

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
                    val hit = if (deep) {
                        matchesMemo(root, event, detector)
                    } else {
                        matches(root, event, detector, deep = false)
                    }
                    if (hit) {
                        countMisses.remove(pkg)
                        contentCounter.onReelSurfaceSeen(pkg)
                        return
                    }
                }
            }
            countMisses[pkg] = (misses + 1) % (DFS_SKIP + 1)
            // We actively checked a reel app's window and found NO reel surface —
            // the user is on a non-reel screen (e.g. the feed). Distinct from "no
            // event" (passive watching), which never reaches here and keeps the
            // bubble up.
            contentCounter.onNoReelSurface(pkg)
        } finally {
            root.recycleSafe()
        }
    }

    /**
     * EVO-024: is the scrolled view the platform's declared reel pager? `null`
     * when no platform of this package declares a `pagerViewId` (the common
     * case — costs nothing) or when the event carries no source; otherwise one
     * `getSource()` binder read per scroll event, compared against the
     * declared id(s). Only the awareness counter consumes the verdict.
     */
    private fun pagerVerdict(event: AccessibilityEvent, platforms: List<PlatformRule>): Boolean? {
        var declared = false
        for (p in platforms) if (p.pagerViewId != null) { declared = true; break }
        if (!declared) return null
        val source = event.source ?: return null
        val sourceId = try {
            source.viewIdResourceName
        } finally {
            source.recycleSafe()
        }
        for (p in platforms) if (p.pagerViewId != null && p.pagerViewId == sourceId) return true
        return false
    }

    /**
     * Whether [pkg] is the currently selected soft keyboard. Its window emits
     * WINDOW_STATE_CHANGED under its own package; read on those events only
     * (rare), uncached because the user can switch keyboards at any time.
     */
    private fun isImePackage(pkg: String): Boolean {
        val ime = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        return ime != null && pkg == ime.substringBefore('/')
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
    private fun handleBrowser(pkg: String, paused: Boolean = false) {
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
        // During a Pause we are only here to let a STRICT host rule match, so the
        // user's own blocklist (which a Pause has always lifted) is skipped
        // entirely and the rule pass is narrowed to opted-in entries.
        val match = if (paused) null else webEngine.matchHost(host)
        // A website schedule (pushRules) is checked after the user's blocklist
        // and the adult set; its hit is named like a RULE hit, with its reason.
        val rule = if (match == null) {
            ruleEngine.blockingForHost(host, System.currentTimeMillis(), strictOnly = paused)
        } else {
            null
        }
        if (match == null && rule == null) {
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
        // left out of the event (Dart's per-host tally / "Most blocked" skip it),
        // out of the toast and off the wall. User-rule hits stay attributable.
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
        // EVO-011: make the intervention legible — the wall attributes the
        // bounce; the toast is the fallback when no wall can be raised.
        val shown = raiseWall(
            BlockScreenPayload(
                referenceType = BlockScreenPayload.TYPE_WEBSITE,
                referenceId = if (adult) "" else host,
                displayName = if (adult) "" else host,
                appLabel = appLabel(pkg),
                packageName = pkg,
                blockReason = when {
                    adult -> BlockScreenPayload.REASON_ADULT
                    rule != null -> rule.reason
                    else -> BlockScreenPayload.REASON_WEB_RULE
                },
                // M8: offer "Unblock for a while" only when a grant could
                // actually free this host. A strict rule is never liftable, and
                // a host on BOTH the user's blocklist and the 18+ set wins its
                // match on the rule arm — so the button would mint a grant and
                // the next visit would still be blocked, now unnamed. ADULT
                // hits are already forced false by `sanitised()` (EVO-018).
                offersUnblock = when {
                    adult -> false
                    rule != null -> false
                    else -> !webEngine.matchesAdult(host)
                },
            ),
            backStaysOver(pkg),
            raisedOver = pkg,
        )
        if (!shown) {
            Toast.makeText(
                this,
                if (adult) getString(R.string.toast_blocked_adult) else getString(R.string.toast_blocked, host),
                Toast.LENGTH_SHORT,
            ).show()
        }
        pressBackWithRateLimit()
    }

    // ---- Block execution ---------------------------------------------------

    /**
     * [ruleReason] set = a rule (SCHEDULE / DAILY_LIMIT) forced this block over
     * the plan. [offersUnblock] false = a strict rule did, and a per-target
     * grant can never lift one, so the wall must not offer the button (M8).
     */
    private fun onDetected(
        pkg: String,
        platformId: String,
        detector: DetectorRule,
        ruleReason: String? = null,
        ruleUnlocksAtMs: Long = -1L,
        offersUnblock: Boolean = true,
    ) {
        val now = System.currentTimeMillis()
        if (now - lastBlockTime <= BLOCK_DEBOUNCE_MS) return
        lastBlockTime = now

        var mode = resolveBlockMode(detector)
        // A rule must bounce: the count-only NONE mode falls back to a BACK press.
        if (ruleReason != null && mode == "NONE") mode = "PRESS_BACK"
        // `now` is this block's one clock read; yesterday's key comes from it
        // too (Calendar arithmetic, so a DST day is still one day).
        store.recordBlock(dateKey(), DateKeys.dayBefore(now), pkg)
        val stats = store.blockStats(dateKey(), DateKeys.dayBefore(now))
        val reason = ruleReason ?: BlockScreenPayload.REASON_PLAN

        // The wall accompanies the navigation below, never replaces it: with
        // no overlay grant the user is still bounced. Raised for the
        // BLOCK_SCREEN mode or a forced block — a spent limit, a schedule, a
        // drained Conscious bank (WallPolicy); NONE navigates nowhere, and a
        // wall over a still-playing reel would be a trap. Wanted but not shown
        // (no grant) falls back to the legacy toast, as the app and website
        // sites do, so the block is never silent.
        val forced = WallPolicy.forced(reason, activePlan, consciousBank)
        val wanted = WallPolicy.reelWall(store.defaultBlockMode, mode, forced)
        var shown = false
        if (wanted) {
            val payload = reelPayload(pkg, platformId, ruleReason, ruleUnlocksAtMs, offersUnblock)
            shown = raiseWall(payload, backStaysOver(pkg), raisedOver = pkg)
            if (!shown) {
                Toast.makeText(
                    this, getString(R.string.toast_blocked, payload.displayName), Toast.LENGTH_SHORT,
                ).show()
            }
        }
        ServiceEventBus.post(
            "blocked",
            mapOf("package" to pkg, "platformId" to platformId, "mode" to mode,
                "today" to stats.today, "total" to stats.total,
                "yesterday" to stats.yesterday, "byPackage" to stats.byPackage,
                "reason" to reason, "wall" to shown),
        )
        Log.i(TAG, "blocked $platformId in $pkg via $mode wall=$shown")

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

    // ---- Block screen (intervention wall) ----------------------------------

    /**
     * Raises the wall for a block that is about to be navigated away from.
     * False when the wall is switched off or the overlay grant is missing —
     * the caller then keeps its legacy toast. Only ever called inside one of
     * the debounced block regions, so it never re-adds per event.
     */
    private fun raiseWall(payload: BlockScreenPayload, over: Set<String>, raisedOver: String): Boolean {
        // Two interventions for one moment is worse than either. `tickNudge`
        // guards the other direction, but it runs EARLIER in this same event —
        // so without this a standing card outlives the block and, being added
        // later, sits above the wall taking taps through its NOT_TOUCH_MODAL
        // window.
        NudgeOverlay.hide()
        return BlockScreenOverlay.show(this, payload.sanitised(), over, raisedOver = raisedOver)
    }

    // ---- Soft nudge --------------------------------------------------------

    /**
     * Advances the dwell machine on every event and renders whatever it asks
     * for. Driven from EVERY accessibility event rather than only the window
     * changes, because the idle timeout needs a dense heartbeat — window
     * changes alone are far too sparse inside a feed, and the machine would
     * read a user who is simply scrolling as one who left.
     *
     * The package is the latched [nudgeForegroundPkg], not the event's own: a
     * background app's content-changed event carries its package while the user
     * is somewhere else entirely, and the identity of a stay must only ever move
     * on a real window change.
     */
    private fun tickNudge(nowMs: Long) {
        // Two interventions for one moment is worse than either: while the wall
        // is up the nudge stays silent and any standing card comes down.
        if (BlockScreenOverlay.isShowing()) {
            NudgeOverlay.hide()
            return
        }
        when (val decision = nudge.tick(nudgeForegroundPkg, nowMs, DateKeys.today(nowMs))) {
            is NudgeDecision.Show -> showNudge(decision)
            NudgeDecision.Dismiss -> NudgeOverlay.hide()
            NudgeDecision.None -> Unit
        }
    }

    private fun showNudge(show: NudgeDecision.Show) {
        val shown = NudgeOverlay.show(
            context = this,
            label = appLabel(show.pkg),
            elapsedMs = show.elapsedMs,
            onDismissed = { nudge.onDismissed() },
            // The user's own tap, not an enforcement action: the nudge still
            // never presses BACK and never bounces anyone. It just makes the
            // exit one tap away at the moment they are deciding.
            onLeave = { BlockScreenOverlay.goHome(this) },
        )
        if (!shown) {
            // No overlay grant: nothing was rendered, so re-arm — and report
            // nothing, because nothing happened. (The crossing still counts
            // against the day's budget; without the grant every attempt fails
            // anyway, so there is no state worth unwinding.)
            nudge.onDismissed()
            return
        }
        ServiceEventBus.post(
            "nudgeShown",
            mapOf(
                "package" to show.pkg,
                "elapsedMs" to show.elapsedMs,
                "thresholdMs" to show.thresholdMs,
            ),
        )
    }

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Throwable) {
        pkg
    }

    /** The surface's own name ("Instagram Reels"); the app label when unnamed. */
    private fun platformName(pkg: String, platformId: String): String =
        config.platformsFor(pkg).firstOrNull { it.platformId == platformId }
            ?.platformName?.ifBlank { null } ?: appLabel(pkg)

    /**
     * The wall for a block on a reel surface — the two reel sites share it.
     * [reason] (SCHEDULE / DAILY_LIMIT) replaces PLAN for a rule block;
     * `sanitised()` then drops the plan chip, which would lie.
     */
    private fun reelPayload(
        pkg: String,
        platformId: String,
        reason: String? = null,
        unlocksAtMs: Long = -1L,
        offersUnblock: Boolean = true,
    ): BlockScreenPayload =
        BlockScreenPayload(
            referenceType = BlockScreenPayload.TYPE_REEL,
            referenceId = platformId,
            displayName = platformName(pkg, platformId),
            appLabel = appLabel(pkg),
            packageName = pkg,
            blockReason = reason ?: BlockScreenPayload.REASON_PLAN,
            plan = activePlan,
            allowance = store.reelAllowance,
            // -1 = "don't print": a switched-off counter has a stale number.
            todayCount = if (contentCounter.isEnabled) contentCounter.todayCount() else -1,
            allowanceLeft = if (activePlan == PLAN_ONE_REEL) {
                (store.reelAllowance - store.reelsConsumed).coerceAtLeast(0)
            } else {
                -1
            },
            bankMs = if (activePlan == PLAN_CONSCIOUS) consciousBank else -1L,
            // EVO-028: only a rule block has a window edge to name.
            unlocksAtMs = unlocksAtMs,
            // M8: false when a STRICT rule raised this wall — a grant cannot
            // lift one, so offering the button would promise what it cannot do.
            offersUnblock = offersUnblock,
        )

    /**
     * What an app-block wall stays over: the bounced app plus the launcher its
     * HOME lands on. `resolveActivity` hands back the resolver ("android")
     * while no default launcher is chosen — every HOME-capable package then.
     */
    private fun appBlockStaysOver(pkg: String): Set<String> {
        val home = try {
            packageManager.resolveActivity(
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                PackageManager.MATCH_DEFAULT_ONLY,
            )?.activityInfo?.packageName
        } catch (_: Throwable) {
            null
        }
        return if (home != null && home != "android") setOf(pkg, home) else homePkgs + pkg
    }

    /**
     * What a reel / website wall stays over: the app itself plus wherever the
     * engine's BACK can land — every launcher, and the app it was opened from
     * (EVO-026). Our own windows, System UI and the IME never count as "from".
     */
    private fun backStaysOver(pkg: String): Set<String> {
        val s = HashSet<String>(homePkgs.size + 2)
        s += homePkgs
        s += pkg
        prevForegroundPkg?.let {
            if (it != pkg && it != packageName && it != "com.android.systemui" && !isImePackage(it)) s += it
        }
        return s
    }

    private fun tearDownOverlays() {
        BlockScreenOverlay.hide()
        NudgeOverlay.hide()
        if (screenOffRegistered) {
            screenOffRegistered = false
            runCatching { unregisterReceiver(screenOffReceiver) }
        }
    }

    // ---- Custom whole-app blocks -------------------------------------------

    /**
     * Bounce a blocked app HOME (BACK would just navigate within it). [reason]
     * is APP_BLOCK for an App Blocker lock, SCHEDULE / DAILY_LIMIT for a rule;
     * both share the HOME debounce.
     */
    private fun onAppBlocked(
        pkg: String,
        reason: String = BlockScreenPayload.REASON_APP_BLOCK,
        unlocksAtMs: Long = -1L,
        offersUnblock: Boolean = true,
    ) {
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

        // `now` is this block's one clock read; yesterday's key comes from it
        // too (Calendar arithmetic, so a DST day is still one day).
        store.recordBlock(dateKey(), DateKeys.dayBefore(now), pkg)
        val stats = store.blockStats(dateKey(), DateKeys.dayBefore(now))
        val token = if (reason == BlockScreenPayload.REASON_APP_BLOCK) "app_block" else "rule"
        ServiceEventBus.post(
            "blocked",
            mapOf(
                "package" to pkg, "platformId" to token, "mode" to "HOME",
                "today" to stats.today, "total" to stats.total,
                "yesterday" to stats.yesterday, "byPackage" to stats.byPackage,
                "reason" to reason,
            ),
        )
        Log.i(TAG, "blocked $token in $pkg via HOME")
        val label = appLabel(pkg)
        // The wall stays over the launcher the HOME below lands on, until the
        // user acts on it; the toast is the fallback when it cannot be raised.
        val shown = raiseWall(
            BlockScreenPayload(
                referenceType = BlockScreenPayload.TYPE_APP,
                referenceId = pkg,
                displayName = label,
                appLabel = label,
                packageName = pkg,
                blockReason = reason,
                // EVO-028: -1 for an App Blocker lock (it has no end), the
                // window edge for a rule.
                unlocksAtMs = unlocksAtMs,
                // M8: false only when a STRICT rule raised this wall.
                offersUnblock = offersUnblock,
            ),
            appBlockStaysOver(pkg),
            raisedOver = pkg,
        )
        if (!shown) {
            Toast.makeText(this, getString(R.string.toast_blocked, label), Toast.LENGTH_SHORT).show()
        }
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
                lastReelPlatformId = ""
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

        // M8 needs no case here. The block loop clears `lastReelAtMs` on the
        // granted arm, which lands in the "lingering in a reel app" branch
        // below: no drain, no accrue — the freeze, exactly. Freezing per
        // PACKAGE instead would stop the bank draining for every OTHER surface
        // in the same app (Stories while Reels is granted), which is a free
        // ride the user never bought.

        // Protected app foreground: freeze the bank and drop any stale
        // "watching" so this 1 Hz timer can never BACK-press into it (the
        // WATCH_STALE_MS window would otherwise survive a reel→bank switch).
        if (isProtected(foregroundPkg)) {
            lastReelAtMs = 0L
            lastReelPlatformId = ""
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
                // The drain-to-empty boot IS the Conscious moment: raise the
                // wall here, not only on the next detection event. A drained
                // bank is a forced block (WallPolicy.forced, EVO-054), so this
                // walls in every mode and past the Appearance switch.
                foregroundPkg?.takeUnless { isProtected(it) }?.let { fg ->
                    // The surface that actually drained the bank — since M8 this
                    // id is what an Unblock tap grants, so guessing the package's
                    // first reel platform would sell the wrong one. With no
                    // stamp (a service restart mid-drain) offer no button rather
                    // than one that grants nothing.
                    val pid = lastReelPlatformId
                    raiseWall(
                        reelPayload(fg, pid, offersUnblock = pid.isNotEmpty()).copy(bankMs = 0L),
                        backStaysOver(fg),
                        raisedOver = fg,
                    )
                }
                lastReelPlatformId = ""
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
     * signal) — only a scroll that lands on a different pager page stamps
     * `lastScrollAtMs` (see the pre-throttle capture), and it only counts as an
     * advance once ≥ 2s have passed since the last count. Together these keep
     * in-reel scrolls (opening comments/captions, a snap-back) from burning the
     * allowance or blocking the reel you're still watching.
     * The currently-playing reel is NEVER blocked; only a fresh reel that appears
     * after the allowance is spent is blocked (which drives the Dart auto-revert).
     *
     * ponytail: reel identity is the pager page at event time (no settle window,
     * unlike the awareness counter's ReelTracker) plus the 2s dwell. A spurious
     * page change > 2s after a count can still be misread as an advance, and a
     * fast advance within 2s of a count is absorbed into the current reel (a
     * small leniency). Upgrade path = drive this gate from ReelTracker too.
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
        oneReelPage = ReelTracker.NO_INDEX
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
        tearDownOverlays()
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
        tearDownOverlays()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "DetoxoService"
        private const val CHANNEL_ID = "detoxo_protection_channel"
        private const val NOTIF_ID = 1125
        private const val THROTTLE_MS = 150L

        /**
         * Cadence of the awareness counter's surface check (its own throttle
         * map; WINDOW_STATE_CHANGED bypasses it). Slower than the block path's
         * [THROTTLE_MS] — which is untouched — because a stage-3 miss on a
         * non-reel screen (the feed) is a full DFS, and a reel's dwell is
         * anchored to the scroll event, not to this check, so the cadence
         * never shifts a measurement. Both passes still share one tree walk
         * per event through the detector memo.
         */
        private const val COUNT_THROTTLE_MS = 400L

        /**
         * Counting-pass checks that skip the stage-3 DFS after a miss before
         * the next full walk (EVO-021). 4 → the DFS runs at most every 5th
         * check (2 s) on a non-reel screen instead of every check.
         */
        private const val DFS_SKIP = 4
        private const val BLOCK_DEBOUNCE_MS = 1200L
        private const val BACK_RATE_LIMIT_MS = 1100L
        private const val MAX_NODES = 12000

        /** Firm single block buzz — longer/stronger than a stray system tap. */
        private const val BLOCK_VIBRATION_MS = 60L

        /**
         * A reel must be watched this long (2s) to count toward the One Reel /
         * Unblock allowance, so a quick flick-through or a single looping reel
         * costs at most one count. Deliberately longer than the awareness
         * counter's 1s "seen" dwell: an allowance is spent on reels *watched*.
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
