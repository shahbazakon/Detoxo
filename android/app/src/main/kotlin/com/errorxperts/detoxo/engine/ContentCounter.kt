package com.errorxperts.detoxo.engine

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import com.errorxperts.detoxo.overlay.ContentCounterBubble
import com.errorxperts.detoxo.widget.ContentCounterWidgetProvider

/**
 * Decides WHEN a distinct short video is counted, persists via
 * [ContentCounterStore], emits the live `contentCounted` event, and drives the
 * home-screen widget + floating bubble.
 *
 * Counting is intentionally INDEPENDENT of blocking: the AccessibilityService
 * feeds it raw signals (foreground app, reel-surface detection, scrolls) from a
 * side-effect-free pass placed before the block logic, so it tallies reels
 * whether or not blocking is enabled, paused, or master-off.
 *
 * Distinct-reel rule (identity + dwell; the state machine is [ReelTracker]):
 *  - A reel is identified by its settled pager page (from the scroll event's
 *    own fromIndex/toIndex) within one continuous stay on a reel surface, so a
 *    snap-back, a comments-sheet scroll, a caption expand or a quick detour to
 *    another app can never count the same reel twice.
 *  - It is counted once it has been the current page for [MIN_VIEW_MS] with no
 *    leave-evidence — stopped on, not flicked past. Passive, event-quiet
 *    playback counts; a device that fell asleep pauses the dwell instead.
 *  - Leave-evidence: the next settled page, a checked window without a reel
 *    surface (after [HIDE_GRACE_MS]), another app in the foreground, the
 *    counter being disabled. A reel that had earned its dwell when it is left
 *    is counted then (belt and braces for a late timer).
 *
 * Bubble visibility:
 *  - SHOWN while a reel/short surface is on screen; stays up the whole time you
 *    watch (even during a passive, event-quiet video — a detection gap never
 *    hides it).
 *  - HIDDEN only on POSITIVE evidence you left reels: a checked window with no
 *    reel surface ([onNoReelSurface], e.g. the feed) after a short grace, or the
 *    foreground switching to another real app ([onForegroundChanged]).
 *  - Ignores our own overlay + system UI so it can't self-toggle (no blink).
 *
 * All state mutates on the accessibility service's single main thread; timers
 * post to that same main Looper, so no locks are needed.
 */
class ContentCounter(private val context: Context) {

    private val store = ContentCounterStore(context)
    private val bubble by lazy { ContentCounterBubble(context) }
    private val power by lazy {
        context.getSystemService(Context.POWER_SERVICE) as PowerManager
    }
    private val handler = Handler(Looper.getMainLooper())
    private val tracker = ReelTracker(MIN_VIEW_MS) { count(it) }
    private val tickRunnable = Runnable {
        tracker.tick(mono(), power.isInteractive)
        syncTimer()
    }
    private val hideRunnable = Runnable {
        hideBubble()
        tracker.leave(mono())
        syncTimer()
    }
    private val widgetRunnable = Runnable { pushWidgetNow(store.snapshot(dateKey())) }

    private var lastReelSurfaceAtMs = 0L
    private var lastForegroundPkg: String? = null
    private var bubbleVisible = false
    private var hidePending = false
    private var lastWidgetPushMs = 0L

    // Whole-app foreground usage-time accumulation (drives the dashboard
    // screen-time ring + the bubble tap-to-reveal). Advances only between events
    // that are close together, so screen-off / idle gaps (no events) start a
    // fresh window and aren't counted.
    private var usageActivePkg: String? = null
    private var usageLastTickMs = 0L

    // Accumulated-but-unwritten usage time. Accessibility events arrive at
    // scroll frequency; writing prefs per event re-serialised the whole file
    // tens of times a second. Flushed at USAGE_FLUSH_MS, on app switch, on
    // snapshot reads, and on dispose.
    // ponytail: <=5s of usage time lost on a hard process kill; a flush that
    // straddles midnight attributes up to the pending window to the wrong day.
    private var pendingUsageMs = 0L

    val isEnabled: Boolean get() = store.enabled

    /** Today's reel count (the bubble's number) — read by the block screen. */
    fun todayCount(): Int = store.todayCount(dateKey())

    /**
     * Today's reel-watching time in ms — the daily reel limit's native meter
     * ([RuleEngine]). A detector match recurs continuously while a reel is on
     * screen, so this ran up to 6.7×/s per matching platform for a value the
     * counter only writes every [USAGE_FLUSH_MS]; the store read (a keyed
     * String compare plus a getLong, both lock-guarded) is memoised for exactly
     * that window, which is the fastest the underlying value can move. The
     * unflushed tail (≤ USAGE_FLUSH_MS) is not included either way.
     */
    fun timeTodayMs(now: Long): Long {
        if (now - meterReadAtMs in 0 until USAGE_FLUSH_MS) return meterCacheMs
        meterCacheMs = store.timeTodayMs(dateKey())
        meterReadAtMs = now
        return meterCacheMs
    }

    @Volatile private var meterCacheMs = 0L
    @Volatile private var meterReadAtMs = Long.MIN_VALUE

    /**
     * Foreground app changed. Tracks the current reel app and hides the bubble
     * when the user leaves for another real app. Ignores our own overlay windows
     * and transient system UI so it can't cause a show/hide loop; the bubble is
     * SHOWN by [onReelSurfaceSeen], not here. The reel session is suspended, not
     * ended — coming back to the same reel resumes it (see [ReelTracker]).
     */
    fun onForegroundChanged(pkg: String, isReelApp: Boolean) {
        if (pkg == context.packageName || pkg in TRANSIENT_PKGS) return
        if (pkg == lastForegroundPkg) return
        // Settle the previous app's usage window — leaving for an unmonitored
        // app means onAppActivity (and its flush) won't fire again.
        flushUsage()
        lastForegroundPkg = pkg
        if (!(isReelApp && pkg == tracker.pkg)) {
            tracker.suspend(mono())
            syncTimer()
        }
        // Any app other than the session's own takes the bubble down — another
        // reel-capable app's feed included (its non-reel screens are not
        // leave-evidence for the suspended session, see onNoReelSurface, so
        // this is the only hide on that path). onReelSurfaceSeen re-shows it
        // as soon as a reel surface is actually on screen.
        if (!(isReelApp && store.enabled && pkg == tracker.pkg)) hideBubble()
    }

    /** A reel/short surface is on screen for [pkg] right now — show + keep it up. */
    fun onReelSurfaceSeen(pkg: String) {
        if (!store.enabled) return
        lastReelSurfaceAtMs = mono()
        lastForegroundPkg = pkg // a reel surface on screen ⇒ pkg is the foreground app
        cancelHide()
        if (store.bubbleEnabled) {
            bubble.show(store.todayCount(dateKey()))
            bubbleVisible = true
        }
        tracker.surfaceSeen(pkg, mono())
        syncTimer()
    }

    /**
     * A monitored app's window was checked and had NO reel surface (e.g. the
     * feed). For the session's own app that is leave-evidence: stamp the
     * current reel's end and schedule a short-grace hide + leave (once), so
     * between-reel transitions don't flicker or end the reel, but leaving reels
     * does. Another monitored app's window (a WhatsApp reply, the YouTube
     * feed) is a detour, already handled by [onForegroundChanged] → suspend,
     * and must not end the session — else the return would recount the reel.
     * Passive watching never reaches here (no event = no check), so it stays
     * visible and keeps dwelling.
     */
    fun onNoReelSurface(pkg: String) {
        if (!store.enabled || hidePending) return
        if (tracker.active && pkg != tracker.pkg) return
        if (!bubbleVisible && !tracker.active) return
        tracker.noSurface(pkg, mono())
        syncTimer()
        hidePending = true
        handler.postDelayed(hideRunnable, HIDE_GRACE_MS)
    }

    /**
     * A scroll happened in [pkg]. The pager's own [fromIndex]/[toIndex] (visible
     * adapter positions, -1 when the view reports none) and [deltaY] (API 28+,
     * else 0) identify the reel; the tracker classifies once the burst settles.
     * [isPager]: the platform's verdict on the scrolled view when it declares a
     * `pagerViewId` (EVO-024), null otherwise.
     */
    fun onScroll(pkg: String, fromIndex: Int, toIndex: Int, deltaY: Int, isPager: Boolean?) {
        if (!store.enabled) return
        tracker.scroll(pkg, fromIndex, toIndex, deltaY, mono(), isPager)
        syncTimer()
    }

    /**
     * The service saw an accessibility event from a monitored social app [pkg].
     * Accrues foreground time between consecutive events on the same app, but
     * only within [USAGE_ACTIVE_GAP_MS] — a longer gap means the screen was off
     * or the user was away (no events), so it starts a fresh window instead of
     * counting the idle time. A different [pkg] also restarts the window.
     *
     * ponytail: active-event heuristic — undercounts truly passive, event-quiet
     * playback. Upgrade path = a 1 Hz foreground ticker while a monitored app is
     * front-most (mirroring the service's Conscious accountant).
     */
    fun onAppActivity(pkg: String) {
        if (!store.enabled) return
        val now = mono() // awake-time clock: a clock change can't mint usage
        if (pkg == usageActivePkg) {
            val delta = now - usageLastTickMs
            if (delta in 1L until USAGE_ACTIVE_GAP_MS) {
                pendingUsageMs += delta
                if (pendingUsageMs >= USAGE_FLUSH_MS) flushUsage()
            }
        } else {
            flushUsage() // app switch: settle the old app's window first
        }
        usageActivePkg = pkg
        usageLastTickMs = now
    }

    /** Writes the accumulated usage time through to the store. */
    private fun flushUsage() {
        if (pendingUsageMs <= 0L) return
        store.recordUsage(pendingUsageMs, dateKey())
        pendingUsageMs = 0L
    }

    /**
     * Privacy: a protected app took the foreground — drop the usage window so
     * the time spent inside it can never be bridged by [USAGE_ACTIVE_GAP_MS]
     * and attributed to the previously-foreground monitored app.
     */
    fun onProtectedForeground() {
        flushUsage()
        usageActivePkg = null
    }

    fun setEnabled(on: Boolean) {
        store.enabled = on
        if (!on) {
            tracker.leave(mono()) // count() is gated on the store, so nothing lands
            syncTimer()
            hideBubble()
        }
    }

    fun setBubbleEnabled(on: Boolean) {
        store.bubbleEnabled = on
        if (on) {
            // Reflect immediately if we're currently on a reel surface.
            if (store.enabled && mono() - lastReelSurfaceAtMs < HIDE_GRACE_MS) {
                bubble.show(store.todayCount(dateKey()))
                bubbleVisible = true
                cancelHide()
            }
        } else {
            hideBubble()
        }
    }

    /**
     * One Reel / Unblock "reels left" override for the bubble: non-null shows the
     * remaining unlock count, null reverts to the today total. Gated on the
     * counter being enabled so a disabled bubble stays hidden (and we don't
     * instantiate the overlay). The bubble's own show/hide still respects
     * [ContentCounterStore.bubbleEnabled] and the on-a-reel-surface condition.
     */
    fun setReelSessionRemaining(n: Int?) {
        if (!store.enabled) return
        bubble.setRemaining(n)
    }

    /** Current counter snapshot (for the pull command). */
    fun snapshot(): Map<String, Any?> {
        flushUsage() // pulls must see the accumulated-but-unwritten time
        return store.snapshot(dateKey())
    }

    /**
     * The bubble's appearance changed (pushed from Dart). Re-render the visible
     * bubble from the freshly-persisted style; the widget is refreshed separately
     * by the command handler. No-op when nothing is on screen.
     */
    fun onStyleChanged() {
        if (bubbleVisible) bubble.onStyleChanged()
    }

    /** Cleanup hook called from the service's onUnbind/onDestroy. */
    fun dispose() {
        flushUsage()
        handler.removeCallbacks(tickRunnable)
        handler.removeCallbacks(hideRunnable)
        handler.removeCallbacks(widgetRunnable)
        bubble.hide()
        bubbleVisible = false
        hidePending = false
    }

    // ── Bubble hide (grace, only on positive "no reel" evidence) ────────────────

    private fun cancelHide() {
        hidePending = false
        handler.removeCallbacks(hideRunnable)
    }

    private fun hideBubble() {
        cancelHide()
        bubble.hide()
        bubbleVisible = false
    }

    // ── Tracker timer (settle + dwell) ─────────────────────────────────────────

    /** Re-arm the single tracker timer from its earliest deadline (idempotent). */
    private fun syncTimer() {
        handler.removeCallbacks(tickRunnable)
        val due = tracker.nextDueAtMs
        if (due > 0L) handler.postDelayed(tickRunnable, (due - mono()).coerceAtLeast(0L))
    }

    // ── Persistence + fan-out ──────────────────────────────────────────────────

    private fun count(pkg: String) {
        if (!store.enabled) return
        // One prefs edit for the count AND the pending usage window (the
        // event's timeTodayMs must include it); the snapshot comes back from
        // the maps that edit already parsed.
        val snap = store.recordCount(pkg, dateKey(), pendingUsageMs)
        pendingUsageMs = 0L
        val today = snap["today"] as? Int ?: 0
        ServiceEventBus.post(
            "contentCounted",
            mapOf(
                "package" to pkg,
                "today" to today,
                "total" to (snap["total"] as? Int ?: 0),
                "perAppToday" to snap["perAppToday"],
                "perAppTotal" to snap["perAppTotal"],
                "timeTodayMs" to (snap["timeTodayMs"] as? Long ?: 0L),
                // Dart's stream mapper defaults missing flags to true — carry
                // the real values so a streamed update can't corrupt them.
                "enabled" to (snap["enabled"] as? Boolean ?: true),
                "bubbleEnabled" to (snap["bubbleEnabled"] as? Boolean ?: true),
            ),
        )
        pushWidget(snap)
        if (store.bubbleEnabled && bubbleVisible) bubble.onCounted(today)
    }

    /**
     * Throttled widget push with a trailing flush: a push inside the window is
     * deferred to the window's end (with a fresh snapshot), never dropped —
     * two counts <1 s apart are routine (belt-and-braces at settle + the next
     * dwell), and a dropped last push left the widget one reel behind for hours.
     */
    private fun pushWidget(snapshot: Map<String, Any?>) {
        handler.removeCallbacks(widgetRunnable)
        val wait = WIDGET_MIN_INTERVAL_MS - (mono() - lastWidgetPushMs)
        if (wait > 0L) {
            handler.postDelayed(widgetRunnable, wait)
            return
        }
        pushWidgetNow(snapshot)
    }

    private fun pushWidgetNow(snapshot: Map<String, Any?>) {
        lastWidgetPushMs = mono()
        try {
            ContentCounterWidgetProvider.pushUpdate(context, snapshot)
        } catch (_: Throwable) {
        }
    }

    /**
     * The one clock in here — reel dwell, scroll settling, usage-time deltas
     * and the widget/bubble throttles. `uptimeMillis` is monotonic (immune to
     * time changes) and, unlike `elapsedRealtime`, STOPS in deep sleep: it is
     * the clock the Handler timer runs on, so a phone that slept for hours
     * mid-reel can't wake up owing a dwell it never showed. Wall time is only
     * ever read through [dateKey].
     */
    private fun mono() = SystemClock.uptimeMillis()

    private fun dateKey(): String = DateKeys.today()

    private companion object {
        /**
         * A reel must be the settled current page this long to count — stopped
         * on, not flicked past. Identity de-dup lives in [ReelTracker], so this
         * is a "you saw it" threshold, not a noise filter. The One Reel
         * allowance keeps its own 2s "watched" dwell in the service.
         */
        const val MIN_VIEW_MS = 1000L

        /**
         * After a checked frame with no reel surface, wait this long before
         * hiding the bubble and ending the reel — bridges between-reel
         * transitions without flicker, but hides shortly after the user lands
         * on a non-reel screen.
         */
        const val HIDE_GRACE_MS = 1500L

        /** Throttle native widget pushes (trailing flush) so a count can't hammer the launcher. */
        const val WIDGET_MIN_INTERVAL_MS = 1000L

        /**
         * Consecutive events from one monitored app within this gap accrue as
         * continuous foreground usage; a longer silence is treated as idle/away
         * and not counted (see [onAppActivity]).
         */
        const val USAGE_ACTIVE_GAP_MS = 12000L

        /** Batch usage-time prefs writes to at most one per this interval. */
        const val USAGE_FLUSH_MS = 5000L

        /**
         * Windows that must NOT be treated as a foreground-app change — our own
         * overlay (would self-trigger a show/hide loop) and the system UI.
         */
        val TRANSIENT_PKGS = setOf("com.android.systemui")
    }
}
