package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Drives [ReelTracker] with literal timestamps; `run` plays the Handler by
 * ticking at each deadline up to a point in time. Dwell = 1000 ms. Timelines
 * are offset by [T0] because, like the rest of the engine, the tracker treats a
 * 0 timestamp as "none" (uptimeMillis is never 0 while the service runs).
 */
class ReelTrackerTest {

    private val counts = mutableListOf<String>()
    private val t = ReelTracker(MIN) { counts += it }

    private fun at(ms: Long) = T0 + ms

    private fun seen(now: Long, pkg: String = IG) = t.surfaceSeen(pkg, at(now))

    private fun swipe(from: Int, to: Int, now: Long, dy: Int = 500, pkg: String = IG) =
        t.scroll(pkg, from, to, dy, at(now))

    private fun run(until: Long, interactive: Boolean = true) {
        while (true) {
            val due = t.nextDueAtMs
            if (due == 0L || due > at(until)) return
            t.tick(due, interactive)
        }
    }

    @Test
    fun watchedReelCountsExactlyOnce() {
        seen(0)
        run(5_000)
        assertEquals(1, counts.size)
        run(60_000) // passive, event-quiet playback: no more calls, no more counts
        assertEquals(1, counts.size)
        assertEquals(0L, t.nextDueAtMs)
    }

    @Test
    fun flickThroughCountsOnlyTheLandingPage() {
        seen(0)
        swipe(1, 1, 400)
        run(800)
        swipe(2, 2, 800)
        run(1_200)
        swipe(3, 3, 1_200)
        run(1_500) // settles page 3, anchored at the swipe
        assertEquals(0, counts.size)
        assertEquals(at(2_200), t.dwellDueAtMs)
        run(5_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun snapBackOnTheSamePageDoesNotRecount() {
        seen(0)
        swipe(1, 1, 300)
        run(1_000) // page 1 from 300
        swipe(1, 1, 800, dy = -200) // half-swipe released
        run(5_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun multiItemListScrollIsIgnored() {
        seen(0)
        run(1_500)
        assertEquals(1, counts.size)
        swipe(3, 9, 2_000) // comments sheet
        run(5_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun pagerWithOnePixelNeighbourAdvancesLikeAnExactOne() {
        seen(0)
        swipe(1, 2, 300)
        run(1_000)
        swipe(2, 3, 2_000)
        run(4_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun multiPageFlingCountsOnlyWhereItLands() {
        seen(0)
        run(1_500)
        swipe(1, 2, 2_000)
        swipe(3, 4, 2_100)
        swipe(7, 7, 2_200)
        run(5_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun firstPeekAfterEntryLearnsThePageInsteadOfAdvancing() {
        seen(0)
        swipe(4, 4, 500, dy = -300) // forward peek that snapped back
        run(2_000)
        assertEquals(1, counts.size)
        swipe(5, 5, 3_000)
        run(6_000)
        assertEquals(2, counts.size)
        swipe(4, 4, 7_000, dy = -400) // back up to the entry reel
        run(9_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun lateTickStillCountsTheReelBeingLeft() {
        seen(0)
        swipe(1, 1, 1_500)
        t.tick(at(1_800), true) // the 1 000 ms tick never ran (main thread busy)
        assertEquals(1, counts.size) // entry reel counted on the advance
        run(5_000)
        assertEquals(2, counts.size) // page 1 on its own dwell
    }

    @Test
    fun appSwitchCountsOnlyIfTheReelEarnedIt() {
        seen(0)
        t.suspend(at(500))
        run(5_000)
        assertEquals(0, counts.size)
        t.leave(at(6_000))
        seen(10_000)
        t.suspend(at(11_500))
        assertEquals(1, counts.size)
    }

    @Test
    fun quickDetourResumesTheSameReel() {
        seen(0)
        run(1_500)
        t.suspend(at(2_000))
        seen(30_000)
        run(40_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun longDetourStartsAFreshSession() {
        seen(0)
        run(1_500)
        t.suspend(at(2_000))
        seen(70_000)
        run(80_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun scrollingBackToACountedPageDoesNotRecount() {
        seen(0)
        run(1_500)
        swipe(1, 1, 2_000)
        run(4_000)
        assertEquals(2, counts.size)
        swipe(0, 0, 5_000, dy = -500)
        run(5_300)
        assertEquals(0L, t.dwellDueAtMs)
        run(9_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun asleepDevicePausesTheDwellWithoutEndingTheSession() {
        seen(0)
        run(5_000, interactive = false)
        assertEquals(0, counts.size)
        assertEquals(0L, t.nextDueAtMs)
        seen(60_000) // unlocked, same reel still playing
        run(65_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun transientMissDoesNotEndTheReel() {
        seen(0)
        t.noSurface(IG, at(400))
        seen(700)
        run(5_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun reelEndsAtTheFirstMissNotAtTheGrace() {
        seen(0)
        t.noSurface(IG, at(900))
        t.leave(at(2_400))
        assertEquals(0, counts.size)
    }

    @Test
    fun scrollOnTheWayOutOfReelsCannotStartACountableReel() {
        seen(0)
        run(1_500)
        t.noSurface(IG, at(2_000))
        swipe(1, 1, 2_200)
        run(2_600)
        t.leave(at(3_500))
        assertEquals(1, counts.size)
    }

    @Test
    fun unindexedPagerFallsBackToDebouncedScrolls() {
        seen(0, SNAP)
        swipe(-1, -1, 500, dy = 0, pkg = SNAP) // inside the dwell: absorbed
        run(2_000)
        assertEquals(1, counts.size)
        swipe(-1, -1, 2_500, dy = 0, pkg = SNAP)
        run(4_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun unindexedScrollInAnIndexedAppIsAnInnerScroll() {
        seen(0)
        swipe(1, 1, 300)
        run(1_000)
        swipe(-1, -1, 2_000, dy = 0) // caption expand
        run(5_000)
        assertEquals(1, counts.size)
    }

    @Test
    fun anotherAppsSurfaceEndsTheOldSession() {
        seen(0)
        seen(500, YT)
        run(2_000)
        assertEquals(listOf(YT), counts)
    }

    @Test
    fun anotherAppsEmptyWindowIsNotLeaveEvidence() {
        seen(0)
        t.noSurface(WA, at(400)) // a WhatsApp window with no reel surface: not IG's evidence
        run(5_000)
        assertEquals(1, counts.size) // the dwell kept running and counted at 1 s
    }

    @Test
    fun anotherAppsEmptyWindowDoesNotEndTheReelEarly() {
        seen(0)
        t.noSurface(WA, at(400)) // must not become the reel's end stamp…
        t.leave(at(1_500)) // …else this leave would read a 400 ms dwell and skip the count
        assertEquals(1, counts.size)
    }

    @Test
    fun indexedScrollFromAKnownNonPagerViewIsIgnored() {
        seen(0)
        run(1_500)
        assertEquals(1, counts.size)
        // A single-comment sheet: (3, 3) would pass as a page without the verdict.
        t.scroll(IG, 3, 3, 500, at(2_000), isPager = false)
        run(5_000)
        assertEquals(1, counts.size)
        // The declared pager itself still advances.
        t.scroll(IG, 1, 1, 500, at(6_000), isPager = true)
        run(9_000)
        assertEquals(2, counts.size)
    }

    @Test
    fun settledPageTable() {
        assertEquals(5, ReelTracker.settledPage(5, 5))
        assertEquals(5, ReelTracker.settledPage(5, 6))
        assertEquals(ReelTracker.IGNORE, ReelTracker.settledPage(3, 9))
        assertEquals(ReelTracker.NO_INDEX, ReelTracker.settledPage(-1, -1))
    }

    private companion object {
        const val MIN = 1_000L
        const val T0 = 100_000L
        const val IG = "com.instagram.android"
        const val YT = "com.google.android.youtube"
        const val SNAP = "com.snapchat.android"
        const val WA = "com.whatsapp"
    }
}
