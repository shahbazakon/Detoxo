package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

/** Pins the pure half of [UsageQuery]: the filters, the wire row shapes and the opens count. */
class UsageQueryTest {

    @Test
    fun startOfDayIsLocalMidnight() {
        val utc = TimeZone.getTimeZone("UTC")
        val day = 86_400_000L
        assertEquals(day, UsageQuery.startOfDay(day + 3_600_000L, utc))
        assertEquals(day, UsageQuery.startOfDay(day, utc))
        assertEquals(day * 2, UsageQuery.startOfDay(day * 2 + 1L, utc))
        // A zone east of UTC has an earlier midnight in epoch terms.
        val kolkata = TimeZone.getTimeZone("Asia/Kolkata") // +05:30
        assertEquals(day - 19_800_000L, UsageQuery.startOfDay(day + 3_600_000L, kolkata))
    }

    @Test
    fun opensCountForegroundTransitionsOnly() {
        val fg = UsageQuery.EVENT_MOVE_TO_FOREGROUND
        val events = sequenceOf(
            "com.a" to fg,
            "com.a" to fg, // the same app resuming its next activity — not a new open
            "com.b" to fg,
            "com.a" to 2, // a MOVE_TO_BACKGROUND never counts
            "com.a" to fg,
            "com.launcher" to fg,
            "com.a" to fg,
        )
        assertEquals(3, UsageQuery.countOpens(events, "com.a"))
        assertEquals(1, UsageQuery.countOpens(events, "com.b"))
        assertEquals(0, UsageQuery.countOpens(events, "com.c"))
        assertEquals(0, UsageQuery.countOpens(emptySequence(), "com.a"))
    }

    @Test
    fun opensByPackageAppliesTheSameTransitionRule() {
        // The watchdog's reconciler reads this map; counting every
        // MOVE_TO_FOREGROUND instead flipped an open limit early with Detoxo
        // closed.
        val fg = UsageQuery.EVENT_MOVE_TO_FOREGROUND
        val events = sequenceOf(
            "com.a" to fg,
            "com.a" to fg,
            "com.b" to fg,
            "com.a" to 2,
            "com.a" to fg,
            "com.launcher" to fg,
            "com.a" to fg,
        )
        val opens = UsageQuery.countOpensByPackage(events)
        assertEquals(3, opens["com.a"])
        assertEquals(1, opens["com.b"])
        assertEquals(1, opens["com.launcher"])
        assertEquals(null, opens["com.c"])
        assertTrue(UsageQuery.countOpensByPackage(emptySequence()).isEmpty())
    }

    @Test
    fun onlyForegroundAndScreenInteractiveEventsSurvive() {
        for (type in 0..40) {
            assertEquals("type $type", type == 1 || type == 18, UsageQuery.keepsEvent(type))
        }
        assertEquals(1, UsageQuery.EVENT_MOVE_TO_FOREGROUND)
        assertEquals(18, UsageQuery.EVENT_SCREEN_INTERACTIVE)
    }

    @Test
    fun zeroForegroundTimeIsDropped() {
        assertFalse(UsageQuery.keepsUsage(0L))
        assertFalse(UsageQuery.keepsUsage(-1L))
        assertTrue(UsageQuery.keepsUsage(1L))
    }

    @Test
    fun boundsMustBeNonNegativeAndOrdered() {
        assertTrue(UsageQuery.validBounds(0L, 1L))
        assertTrue(UsageQuery.validBounds(1_000L, 2_000L))
        assertFalse(UsageQuery.validBounds(2_000L, 2_000L))
        assertFalse(UsageQuery.validBounds(2_000L, 1_000L))
        assertFalse(UsageQuery.validBounds(-1L, 1_000L))
    }

    @Test
    fun wireRowKeysArePinned() {
        assertEquals(
            mapOf("package" to "com.a.b", "foregroundMillis" to 5_000L),
            UsageQuery.usageRow("com.a.b", 5_000L),
        )
        assertEquals(
            mapOf("package" to "com.a.b", "type" to 18, "timestampMillis" to 123L),
            UsageQuery.eventRow("com.a.b", 18, 123L),
        )
    }

    // ── EVO-034: the wall's time-today line ─────────────────────────────────

    @Test
    fun `formatHm renders hours and minutes like the Dart side`() {
        assertEquals("0m", UsageQuery.formatHm(0L))
        assertEquals("12m", UsageQuery.formatHm(12L * 60_000L))
        assertEquals("1h", UsageQuery.formatHm(60L * 60_000L))
        assertEquals("1h 10m", UsageQuery.formatHm(70L * 60_000L))
        assertEquals("3h 12m", UsageQuery.formatHm(192L * 60_000L))
    }

    @Test
    fun `formatHm truncates seconds rather than rounding up`() {
        // 59s is not a minute: the wall must never claim time that has not passed.
        assertEquals("0m", UsageQuery.formatHm(59_000L))
        assertEquals("1m", UsageQuery.formatHm(119_000L))
    }

    @Test
    fun `formatHm never renders a negative span`() {
        assertEquals("0m", UsageQuery.formatHm(-5_000L))
    }
}
