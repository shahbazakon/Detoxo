package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

/** Pins the pure half of the block counters: the per-package tally (EVO-059) and the yesterday rule (EVO-060). */
class BlockTallyTest {

    @Test
    fun recordCountsPerPackageAndParsesBack() {
        var json = BlockTally.record(null, "com.a")
        json = BlockTally.record(json, "com.a")
        json = BlockTally.record(json, "com.b")
        assertEquals(mapOf("com.a" to 2, "com.b" to 1), BlockTally.parse(json))
    }

    @Test
    fun aNewcomerPastTheCapEvictsTheSmallest() {
        var json: String? = null
        repeat(3) { json = BlockTally.record(json, "com.big") }
        json = BlockTally.record(json, "com.small")
        json = BlockTally.record(json, "com.new", cap = 2)
        val tally = BlockTally.parse(json)
        assertEquals(2, tally.size)
        assertEquals(3, tally["com.big"])
        assertEquals(1, tally["com.new"])
        assertNull(tally["com.small"])
        // A known package past the cap is a plain increment, no eviction.
        assertEquals(4, BlockTally.parse(BlockTally.record(json, "com.big", cap = 2))["com.big"])
    }

    @Test
    fun garbageReadsAsAnEmptyDay() {
        assertTrue(BlockTally.parse(null).isEmpty())
        assertTrue(BlockTally.parse("").isEmpty())
        assertTrue(BlockTally.parse("{not json").isEmpty())
        // Non-positive and non-numeric counts are dropped, the rest kept.
        assertEquals(mapOf("com.a" to 2), BlockTally.parse("""{"com.a":2,"com.b":-1,"com.c":"x"}"""))
    }

    @Test
    fun withoutDropsProtectedPackagesOnly() {
        val json = BlockTally.record(BlockTally.record(null, "com.bank"), "com.a")
        assertEquals(mapOf("com.a" to 1), BlockTally.parse(BlockTally.without(json, setOf("com.bank"))))
        assertNull(BlockTally.without(json, setOf("com.none")))
        assertNull(BlockTally.without(null, setOf("com.bank")))
        assertNull(BlockTally.without(json, emptySet()))
    }

    @Test
    fun yesterdayFollowsTheStoredDay() {
        val today = "06-09-2026"
        val yesterday = "05-09-2026"
        // Blocked today already: the rotated pair is yesterday's, if it names yesterday.
        assertEquals(52, BlockTally.yesterday(today, 37, yesterday, 52, today, yesterday))
        assertEquals(0, BlockTally.yesterday(today, 37, "01-09-2026", 52, today, yesterday))
        // No block yet today: the stored day is yesterday, so its count is the answer.
        assertEquals(37, BlockTally.yesterday(yesterday, 37, "", 0, today, yesterday))
        // Nothing since last week: yesterday had none.
        assertEquals(0, BlockTally.yesterday("01-09-2026", 37, "", 0, today, yesterday))
        assertEquals(0, BlockTally.yesterday("", 0, "", 0, today, yesterday))
    }

    @Test
    fun dayBeforeIsCalendarArithmeticNotMinus24h() {
        val berlin = TimeZone.getTimeZone("Europe/Berlin")
        // 2026-03-30 00:30 CEST, the night after the 23-hour DST day: minus 24 h
        // lands on 28 March 23:30 CET, a two-day jump. The key must be the 29th.
        val cal = java.util.Calendar.getInstance(berlin).apply {
            set(2026, java.util.Calendar.MARCH, 30, 0, 30, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
        assertEquals("29-03-2026", DateKeys.dayBefore(cal.timeInMillis, berlin))
        // What `now - 24h` would have answered on that night.
        val naive = java.text.SimpleDateFormat("dd-MM-yyyy", java.util.Locale.US)
            .apply { timeZone = berlin }
            .format(java.util.Date(cal.timeInMillis - 86_400_000L))
        assertEquals("28-03-2026", naive)
        // An ordinary day, and a month boundary.
        cal.set(2026, java.util.Calendar.SEPTEMBER, 1, 12, 0, 0)
        assertEquals("31-08-2026", DateKeys.dayBefore(cal.timeInMillis, berlin))
    }
}
