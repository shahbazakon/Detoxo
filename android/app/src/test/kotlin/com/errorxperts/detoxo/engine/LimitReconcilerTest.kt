package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EVO-029: the arithmetic that lets a daily rule budget start enforcing while
 * Detoxo is closed. Android-free, so it runs on the JVM with the real parser
 * feeding it (entries come out of [RuleEngine.parse]).
 */
class LimitReconcilerTest {

    private fun entry(
        id: String,
        packages: List<String>,
        usageLimitMs: Long = 0L,
        openLimitCount: Int = 0,
        spent: Boolean = false,
    ) = RuleEngine.Entry(
        id = id,
        reason = "DAILY_LIMIT",
        allExcept = false,
        packages = packages.toHashSet(),
        domains = emptyList(),
        platformIds = emptySet(),
        windows = longArrayOf(0L, Long.MAX_VALUE),
        always = false,
        reelTimeLimitMs = 0L,
        strict = false,
        usageLimitMs = usageLimitMs,
        openLimitCount = openLimitCount,
        spent = spent,
    )

    @Test
    fun aTimeBudgetIsSpentAtTheThresholdNotBefore() {
        val e = listOf(entry("t1", listOf(IG), usageLimitMs = 30 * 60_000L))
        assertEquals(
            emptySet<String>(),
            LimitReconciler.spentIds(e, mapOf(IG to 29 * 60_000L), emptyMap()),
        )
        assertEquals(
            setOf("t1"),
            LimitReconciler.spentIds(e, mapOf(IG to 30 * 60_000L), emptyMap()),
        )
        assertEquals(
            setOf("t1"),
            LimitReconciler.spentIds(e, mapOf(IG to 31 * 60_000L), emptyMap()),
        )
    }

    @Test
    fun aCategoryBudgetIsOneSumAcrossItsPackages() {
        // The rule says "30 minutes of short-form video", not "30 minutes each".
        val e = listOf(entry("t1", listOf(IG, TT), usageLimitMs = 30 * 60_000L))
        assertEquals(
            emptySet<String>(),
            LimitReconciler.spentIds(e, mapOf(IG to 20 * 60_000L), emptyMap()),
        )
        assertEquals(
            setOf("t1"),
            LimitReconciler.spentIds(
                e,
                mapOf(IG to 20 * 60_000L, TT to 10 * 60_000L),
                emptyMap(),
            ),
        )
    }

    @Test
    fun openBudgetsCountLaunchesAndUnknownPackagesContributeNothing() {
        val e = listOf(entry("o1", listOf(IG, TT), openLimitCount = 5))
        assertEquals(
            emptySet<String>(),
            LimitReconciler.spentIds(e, emptyMap(), mapOf(IG to 4, "com.absent" to 99)),
        )
        assertEquals(
            setOf("o1"),
            LimitReconciler.spentIds(e, emptyMap(), mapOf(IG to 4, TT to 1)),
        )
    }

    @Test
    fun nothingToDoWithoutPendingEntries() {
        assertEquals(
            emptySet<String>(),
            LimitReconciler.spentIds(emptyList(), mapOf(IG to Long.MAX_VALUE), emptyMap()),
        )
    }

    @Test
    fun aFlippedLimitStartsBlockingAndArmsThePackageArm() {
        // The whole point: parse a PENDING budget, confirm it blocks nothing,
        // then reconcile it and confirm it does.
        val engine = RuleEngine()
        engine.setSnapshot(
            """[{"id":"t1","reason":"DAILY_LIMIT","mode":"BLOCK","packages":["$IG"],""" +
                """"domains":[],"platformIds":[],"windows":[[0,${Long.MAX_VALUE}]],""" +
                """"always":false,"reelTimeLimitMs":0,"strict":false,""" +
                """"usageLimitMs":${30 * 60_000},"openLimitCount":0,"spent":false}]""",
        )
        assertTrue(engine.hasPendingLimits())
        assertEquals(null, engine.blockingForPackage(IG, 1_000L))
        assertEquals(false, engine.hasPackageRules())

        val ids = LimitReconciler.spentIds(
            engine.pendingLimits(),
            mapOf(IG to 30 * 60_000L),
            emptyMap(),
        )
        assertTrue(engine.markSpent(ids))
        assertEquals("t1", engine.blockingForPackage(IG, 1_000L)?.id)
        assertTrue(engine.hasPackageRules())
        assertEquals(false, engine.hasPendingLimits())
        // Idempotent: a second pass with the same measurement changes nothing.
        assertEquals(false, engine.markSpent(ids))
    }

    private companion object {
        const val IG = "com.instagram.android"
        const val TT = "com.zhiliaoapp.musically"
    }
}
