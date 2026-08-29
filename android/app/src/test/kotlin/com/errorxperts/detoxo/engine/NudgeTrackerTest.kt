package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Scenario table for the soft-nudge dwell machine.
 *
 * Timelines are minutes from [T0] — the tracker only ever compares timestamps,
 * so any origin does, and offsets keep the arithmetic readable.
 *
 * [stay] is the important helper: it replays the dense event heartbeat the
 * accessibility service actually delivers (every accessibility event, not only
 * the window changes), because the idle rule is written against that. Tests
 * that use bare [at] are deliberately testing the sparse case.
 */
class NudgeTrackerTest {

    private val t = tracker()
    private val cards = mutableListOf<NudgeDecision.Show>()

    private fun tracker(step: Long = STEP, idle: Long = IDLE, cap: Int = CAP) =
        NudgeTracker(step, idle, cap).apply {
            configure(
                enabled = true,
                packages = setOf(IG, YT),
                thresholdStepMs = step,
                dailyCap = cap,
                idleTimeoutMs = idle,
            )
        }

    private fun ms(min: Double) = T0 + (min * 60_000L).toLong()

    /** One event for [pkg] at [min] minutes past T0; collects any card raised. */
    private fun at(min: Double, pkg: String? = IG, day: String = DAY): NudgeDecision {
        val d = t.tick(pkg, ms(min), day)
        if (d is NudgeDecision.Show) cards += d
        return d
    }

    /**
     * The user is in [pkg] from [from] to [to] minutes, generating an event
     * every half minute. Auto-dismisses each card, as the overlay's own 6 s
     * timer does, so the machine re-arms for the next threshold.
     */
    private fun stay(from: Double, to: Double, pkg: String? = IG, day: String = DAY) {
        var m = from
        while (m <= to + 1e-9) {
            if (at(m, pkg, day) is NudgeDecision.Show) t.onDismissed()
            m += 0.5
        }
    }

    private fun shows(d: NudgeDecision): NudgeDecision.Show {
        assertTrue("expected Show, got $d", d is NudgeDecision.Show)
        return d as NudgeDecision.Show
    }

    // ── The thresholds ────────────────────────────────────────────────────────

    @Test
    fun noNudgeBeforeTheFirstThreshold() {
        stay(0.0, 4.5)
        assertEquals(0, cards.size)
    }

    @Test
    fun firesExactlyOnceAtTheFirstThreshold() {
        stay(0.0, 4.5)
        val card = shows(at(5.0))
        assertEquals(IG, card.pkg)
        assertEquals(5 * 60_000L, card.thresholdMs)
        assertEquals(5 * 60_000L, card.elapsedMs)
        // Still in the app with the card up: no second card at the same crossing.
        assertEquals(NudgeDecision.None, at(5.5))
        assertEquals(1, cards.size)
    }

    @Test
    fun firesAtEveryStepWhenTheUserStays() {
        stay(0.0, 15.0)
        assertEquals(
            listOf(5 * 60_000L, 10 * 60_000L, 15 * 60_000L),
            cards.map { it.thresholdMs },
        )
    }

    @Test
    fun theWatermarkAdvancesOneStepPerCrossingNotToTheTotal() {
        // A step shorter than the idle timeout is the only way one event can
        // straddle two thresholds — the guarantee the plan is emphatic about.
        val fast = tracker(step = 20_000L)
        fast.tick(IG, T0, DAY)
        // 50 s in: past 20 s AND past 40 s. Exactly one card, for the 20 s mark.
        val first = fast.tick(IG, T0 + 50_000L, DAY) as NudgeDecision.Show
        assertEquals(20_000L, first.thresholdMs)
        assertEquals(50_000L, first.elapsedMs)
        fast.onDismissed()
        // The next event picks up the second step — one per event, never queued.
        val second = fast.tick(IG, T0 + 55_000L, DAY) as NudgeDecision.Show
        assertEquals(40_000L, second.thresholdMs)
    }

    // ── Session lifetime ──────────────────────────────────────────────────────

    @Test
    fun idleLongerThanTheTimeoutRestartsTheClock() {
        stay(0.0, 2.0)
        stay(2.0, 4.0, pkg = OTHER) // 2 min with no IG event ends the session
        stay(4.0, 8.5) // back in IG: a fresh clock, so 5 min in is 9 min on the wall
        assertEquals(0, cards.size)
        shows(at(9.0))
    }

    @Test
    fun aShortDetourKeepsTheSession() {
        stay(0.0, 2.0)
        at(2.5, pkg = OTHER) // away, but the next IG event lands within IDLE
        stay(3.0, 4.5)
        shows(at(5.0))
    }

    @Test
    fun anOvernightGapInTheSameAppNeverClaimsEightHours() {
        stay(0.0, 2.0)
        // Phone locked in Instagram, picked up in the morning: the stale
        // session must not survive to report 480 minutes.
        assertEquals(NudgeDecision.None, at(480.0))
        assertEquals(NudgeDecision.None, at(480.5))
    }

    @Test
    fun switchingDistractingAppsStartsAFreshSession() {
        stay(0.0, 4.0)
        stay(4.0, 8.5, pkg = YT) // new app → new session, watermark back at zero
        assertEquals(0, cards.size)
        assertEquals(YT, shows(at(9.0, pkg = YT)).pkg)
    }

    @Test
    fun leavingTheAppTakesTheCardAway() {
        stay(0.0, 4.5)
        shows(at(5.0))
        assertEquals(NudgeDecision.Dismiss, at(5.2, pkg = OTHER))
        // Only once — there is no card left to dismiss.
        assertEquals(NudgeDecision.None, at(5.3, pkg = OTHER))
    }

    @Test
    fun stayingInTheAppDoesNotKillTheCard() {
        stay(0.0, 4.5)
        shows(at(5.0))
        // Window changes inside the app (a story, a comment sheet) must not
        // dismiss a card a second old — the overlay's own timer owns that.
        assertEquals(NudgeDecision.None, at(5.05))
        assertEquals(NudgeDecision.None, at(5.1))
    }

    @Test
    fun dismissThenStayReArmsAtTheNextThreshold() {
        stay(0.0, 4.5)
        shows(at(5.0))
        assertEquals(NudgeDecision.None, at(5.5)) // card still up: no re-nudge
        t.onDismissed()
        stay(6.0, 9.5)
        assertEquals(1, cards.size) // re-armed, but not yet due
        shows(at(10.0))
    }

    // ── Gates ─────────────────────────────────────────────────────────────────

    @Test
    fun aNonDistractingAppNeverFires() {
        stay(0.0, 30.0, pkg = OTHER)
        assertEquals(0, cards.size)
    }

    @Test
    fun aNullPackageNeverFires() {
        stay(0.0, 30.0, pkg = null)
        assertEquals(0, cards.size)
    }

    @Test
    fun disabledIsAHardNoOp() {
        t.configure(enabled = false, packages = setOf(IG, YT), thresholdStepMs = STEP, dailyCap = CAP)
        stay(0.0, 60.0)
        assertEquals(0, cards.size)
    }

    @Test
    fun aProtectedAppIsNotInTheWatchList() {
        // The caller subtracts the protected set before pushing. Whatever the
        // foreground latch says, an app that is not in the set cannot nudge.
        t.configure(enabled = true, packages = setOf(YT), thresholdStepMs = STEP, dailyCap = CAP)
        stay(0.0, 30.0, pkg = IG)
        assertEquals(0, cards.size)
    }

    // ── Config pushes must not hand out a fresh budget ────────────────────────

    @Test
    fun anUnchangedConfigPushKeepsTheDayTally() {
        stay(0.0, 5.0 * CAP) // burn the whole cap
        assertEquals(CAP, cards.size)
        // Every app resume re-pushes the identical config. It must not refill.
        repeat(3) {
            t.configure(enabled = true, packages = setOf(IG, YT), thresholdStepMs = STEP, dailyCap = CAP)
        }
        stay(5.0 * CAP, 5.0 * (CAP + 2))
        assertEquals(CAP, cards.size)
    }

    @Test
    fun anUnchangedConfigPushKeepsTheLiveSession() {
        stay(0.0, 4.5)
        // A settings write mid-stay (theme, vibration…) reaches the engine as a
        // push. The clock must not restart, or 5 minutes never arrives.
        t.configure(enabled = true, packages = setOf(IG, YT), thresholdStepMs = STEP, dailyCap = CAP)
        shows(at(5.0))
    }

    @Test
    fun changingTheThresholdRestartsTheStayButKeepsTheTally() {
        stay(0.0, 5.0)
        assertEquals(1, cards.size)
        // The watermark is denominated in the old step, so the stay resets…
        t.configure(enabled = true, packages = setOf(IG, YT), thresholdStepMs = 10 * 60_000L, dailyCap = CAP)
        stay(5.0, 14.5)
        assertEquals(1, cards.size)
        shows(at(15.0)) // 10 min after the reconfigure, not after the open
        assertEquals(2, cards.size)
    }

    @Test
    fun disablingClearsTheLiveSession() {
        stay(0.0, 4.5)
        t.configure(enabled = false, packages = setOf(IG, YT), thresholdStepMs = STEP, dailyCap = CAP)
        t.configure(enabled = true, packages = setOf(IG, YT), thresholdStepMs = STEP, dailyCap = CAP)
        assertEquals(NudgeDecision.None, at(5.0)) // fresh clock, not 5 min in
        stay(5.5, 9.5)
        shows(at(10.0))
    }

    // ── Clock ─────────────────────────────────────────────────────────────────

    @Test
    fun aBackwardsClockEndsTheStayInsteadOfWedgingIt() {
        stay(0.0, 4.0)
        // NTP correction / the user setting the date back an hour. `elapsed`
        // would go negative and suppress every nudge until the clock caught up.
        assertEquals(NudgeDecision.None, at(-60.0))
        stay(-59.5, -55.5)
        shows(at(-55.0)) // a fresh stay on the new clock, 5 min in
    }

    @Test
    fun theDailyCapStopsFurtherNudges() {
        stay(0.0, 5.0 * (CAP + 1))
        assertEquals(CAP, cards.size)
    }

    @Test
    fun theCapIsPerAppNotGlobal() {
        stay(0.0, 5.0 * (CAP + 1))
        assertEquals(CAP, cards.size)
        // A different distracting app has its own budget.
        stay(100.0, 105.0, pkg = YT)
        assertEquals(YT, cards.last().pkg)
    }

    @Test
    fun aDayRolloverClearsTheCap() {
        stay(0.0, 5.0 * (CAP + 1))
        assertEquals(CAP, cards.size)
        // Tomorrow: the tally resets even mid-stay.
        stay(5.0 * (CAP + 1), 5.0 * (CAP + 2), day = TOMORROW)
        assertEquals(CAP + 1, cards.size)
    }

    @Test
    fun resetForgetsTheLiveSession() {
        stay(0.0, 4.0)
        t.reset()
        stay(4.0, 8.5)
        assertEquals(0, cards.size)
        shows(at(9.0))
    }

    private companion object {
        const val STEP = 300_000L
        const val IDLE = 60_000L
        const val CAP = 4
        const val T0 = 100_000L
        const val DAY = "04-09-2026"
        const val TOMORROW = "05-09-2026"
        const val IG = "com.instagram.android"
        const val YT = "com.google.android.youtube"
        const val OTHER = "com.errorxperts.notes"
    }
}
