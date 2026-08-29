package com.errorxperts.detoxo.engine

/**
 * Reel identity + dwell state machine behind the awareness counter.
 *
 * Pure Kotlin (no Android imports): every entry point takes a monotonic `now`
 * (`SystemClock.uptimeMillis` in production — the Handler's own clock, which
 * stops in deep sleep so a sleeping phone accrues no dwell; literals in the
 * unit test) and publishes its next deadline via [nextDueAtMs];
 * [ContentCounter] owns the one Handler that calls [tick] when it is due.
 *
 * Model
 *  - A SESSION is one continuous stay on a reel surface in one app ([pkg]). It
 *    ends on positive leave-evidence ([leave]) and is only *suspended* by an
 *    app switch ([suspend]), so a quick detour (notification reply) back to the
 *    same reel never recounts it.
 *  - A REEL is identified by its settled pager page within the session. Pages
 *    come straight from the fields a pager already puts on every
 *    TYPE_VIEW_SCROLLED event (RecyclerView / ViewPager: fromIndex..toIndex =
 *    visible adapter positions): a full-screen pager at rest shows one page
 *    (or one page plus a 1 px neighbour), a comments list shows several. The
 *    tracker keeps the latest snapshot and classifies it once the burst has
 *    been quiet for [SCROLL_SETTLE_MS] — the last event of a fling is the
 *    settled state (the system coalesces scroll events, so intermediate frames
 *    are unreliable anyway).
 *  - A reel COUNTS once it has been the current page for [minViewMs] with no
 *    leave-evidence (so passive, event-quiet playback counts) or — belt and
 *    braces for a late tick — when it is left after at least that long.
 *
 * ponytail: ceilings, each ≤ 1 phantom or miss per occurrence —
 *  (a) a one-or-two-item inner list (single-comment sheet, one-item carousel)
 *      settles like a pager page — on platforms WITHOUT a `pagerViewId`
 *      (EVO-024): with one declared, scrolls from any other view arrive with
 *      `isPager = false` and are ignored as page evidence;
 *  (b) unindexed pagers (fromIndex = -1) fall back to any-scroll + dwell
 *      debounce; upgrade path = event.scrollY / page height;
 *  (c) the entry reel's page is unknown until the first settle — assumed to be
 *      `firstPage - 1` so scrolling back up to it does not recount;
 *  (d) holding a *backward* peek for a whole dwell reads as the previous page.
 */
class ReelTracker(
    private val minViewMs: Long,
    private val onCount: (pkg: String) -> Unit,
) {
    /** App of the current session; null = no session. */
    var pkg: String? = null
        private set

    private var index = NO_INDEX
    private var startMs = 0L // dwell anchor; 0 = paused (asleep / away)
    private var counted = false
    private var noSurfaceAtMs = 0L // first miss in this reel = its end time
    private var awayAtMs = 0L // suspend() stamp; 0 = not away
    private var scrollFrom = NO_INDEX
    private var scrollTo = NO_INDEX
    private var scrollDeltaY = 0
    private var scrollIsPager: Boolean? = null // false = a known non-pager view
    private var scrollAtMs = 0L // latest scroll snapshot; 0 = none pending
    private val countedPages = HashSet<Int>()
    private var synthetic = SYNTHETIC_START
    private val indexedPkgs = HashSet<String>()

    val active: Boolean get() = pkg != null

    /** When the dwell must be judged; 0 = no dwell running. */
    val dwellDueAtMs: Long
        get() = if (pkg != null && !counted && startMs > 0L && noSurfaceAtMs == 0L) {
            startMs + minViewMs
        } else {
            0L
        }

    /** When the pending scroll burst counts as settled; 0 = none pending. */
    val settleDueAtMs: Long
        get() = if (scrollAtMs > 0L) scrollAtMs + SCROLL_SETTLE_MS else 0L

    /** Earliest pending deadline; 0 = nothing to schedule. */
    val nextDueAtMs: Long
        get() {
            val dwell = dwellDueAtMs
            val settle = settleDueAtMs
            return when {
                dwell == 0L -> settle
                settle == 0L -> dwell
                else -> minOf(dwell, settle)
            }
        }

    /** A reel surface of [pkg] is on screen: start, resume or continue a session. */
    fun surfaceSeen(pkg: String, now: Long) {
        if (this.pkg != pkg || (awayAtMs > 0L && now - awayAtMs > AWAY_EXPIRY_MS)) {
            leave(now)
            this.pkg = pkg
            startMs = now
            return
        }
        awayAtMs = 0L
        noSurfaceAtMs = 0L
        if (startMs == 0L && !counted) startMs = now // resume after pause()/suspend()
    }

    /**
     * A checked window of [pkg] had no reel surface: if it is the session's own
     * app, stamp the reel's end once. Another app's window is a detour (handled
     * by [suspend]) — a WhatsApp reply or the YouTube feed must never end an
     * Instagram session, or the return would recount the same reel.
     */
    fun noSurface(pkg: String, now: Long) {
        if (this.pkg == pkg && noSurfaceAtMs == 0L) noSurfaceAtMs = now
    }

    /**
     * TYPE_VIEW_SCROLLED in [pkg]: keep the latest snapshot; [tick] classifies
     * it once settled. [isPager] is the platform's verdict on the scrolled view
     * (EVO-024): `false` = a known non-pager view (its indices are never page
     * evidence), `true` / `null` (no `pagerViewId` declared) = classify as usual.
     */
    fun scroll(
        pkg: String,
        fromIndex: Int,
        toIndex: Int,
        deltaY: Int,
        now: Long,
        isPager: Boolean? = null,
    ) {
        if (this.pkg != pkg || awayAtMs > 0L) return
        scrollFrom = fromIndex
        scrollTo = toIndex
        scrollDeltaY = deltaY
        scrollIsPager = isPager
        scrollAtMs = now
    }

    /** Timer callback: settle a pending scroll and/or judge the dwell. [interactive] = device awake. */
    fun tick(now: Long, interactive: Boolean) {
        if (settleDueAtMs in 1L..now) settle()
        if (dwellDueAtMs in 1L..now) {
            if (interactive) count() else pause()
        }
    }

    /** Another app took the foreground: keep the session, freeze the dwell. */
    fun suspend(now: Long) {
        if (pkg == null) return
        finish(now)
        startMs = 0L
        awayAtMs = now
        scrollAtMs = 0L
    }

    /** Positive leave-evidence: end the session (counting the reel if it earned it). */
    fun leave(now: Long) {
        if (pkg == null) return
        finish(now)
        pkg = null
        index = NO_INDEX
        startMs = 0L
        counted = false
        noSurfaceAtMs = 0L
        awayAtMs = 0L
        scrollAtMs = 0L
        countedPages.clear()
        synthetic = SYNTHETIC_START
    }

    /** Device asleep at tick time: freeze the dwell without ending the session. */
    private fun pause() {
        if (!counted) startMs = 0L
    }

    private fun settle() {
        val at = scrollAtMs
        scrollAtMs = 0L
        val p = pkg ?: return
        // A scroll from a view the platform knows is not its pager is an inner
        // scroll whatever its indices say (comments sheet, one-item carousel).
        val page = if (scrollIsPager == false) IGNORE else settledPage(scrollFrom, scrollTo)
        val next = when (page) {
            IGNORE -> return
            NO_INDEX -> {
                // Unindexed view. In an app whose pager reports pages this is an
                // inner scroll (caption, sheet); otherwise legacy any-scroll,
                // debounced by the dwell so in-reel scrolls don't advance.
                if (p in indexedPkgs || startMs == 0L || at - startMs < minViewMs) return
                synthetic--
            }
            else -> {
                indexedPkgs.add(p)
                page
            }
        }
        if (next == index) return // snap-back / same page
        if (index == NO_INDEX && page != NO_INDEX && scrollDeltaY < 0) {
            // First settle on the entry reel finished moving backwards: a
            // forward-peek snap-back, not an advance — just learn the page.
            index = next
            return
        }
        advance(next, at)
    }

    private fun advance(page: Int, at: Long) {
        finish(at)
        if (index == NO_INDEX && counted && page > 0) countedPages.add(page - 1) // ceiling (c)
        index = page
        counted = page in countedPages
        startMs = at
        // noSurfaceAtMs is deliberately kept: only a fresh surfaceSeen clears
        // no-surface evidence, so a scroll on the way out of reels can't start
        // a countable reel.
    }

    /** The current reel is being left at [endMs]: count it if it was on screen long enough. */
    private fun finish(endMs: Long) {
        if (counted || startMs == 0L) return
        val end = if (noSurfaceAtMs != 0L) minOf(noSurfaceAtMs, endMs) else endMs
        if (end - startMs >= minViewMs) count()
    }

    private fun count() {
        counted = true
        if (index != NO_INDEX) countedPages.add(index)
        onCount(pkg ?: return)
    }

    companion object {
        /** No page information (unindexed view / nothing settled yet). */
        const val NO_INDEX = -1

        /** A multi-item list (comments, grid) — never a reel advance. */
        const val IGNORE = -2

        private const val SYNTHETIC_START = -3

        /** A detour to another app longer than this starts a fresh session on return. */
        const val AWAY_EXPIRY_MS = 60_000L

        /** A scroll burst quiet for this long is settled. */
        const val SCROLL_SETTLE_MS = 300L

        /**
         * Page identity of a TYPE_VIEW_SCROLLED snapshot: the first visible
         * adapter position when at most two items are visible (a full-screen
         * pager at rest shows one page, or one page plus a 1 px neighbour),
         * [IGNORE] for a multi-item list, [NO_INDEX] when the view reports none.
         * Shared with the One Reel gate in the service.
         */
        fun settledPage(fromIndex: Int, toIndex: Int): Int = when {
            fromIndex < 0 -> NO_INDEX
            toIndex - fromIndex <= 1 -> fromIndex
            else -> IGNORE
        }
    }
}
