package com.errorxperts.detoxo.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [RuleEngine] against hand-built snapshots in the Dart `SnapshotEntry`
 * wire shape. `org.json` is the real artifact on the test classpath (see
 * build.gradle.kts), so the parse itself is exercised here.
 */
class RuleEngineTest {

    private val engine = RuleEngine()

    private fun entry(
        id: String = "r1",
        strict: Boolean = false,
        reason: String = "SCHEDULE",
        mode: String = "BLOCK",
        packages: String = "",
        domains: String = "",
        platforms: String = "",
        windows: String = "",
        always: Boolean = false,
        reelMs: Long = 0L,
    ) = """{"id":"$id","reason":"$reason","mode":"$mode","packages":[$packages],""" +
        """"domains":[$domains],"platformIds":[$platforms],"windows":[$windows],""" +
        """"always":$always,"reelTimeLimitMs":$reelMs,"strict":$strict}"""

    private fun open() = "[${T - 1_000},${T + 1_000}]"

    @Test
    fun emptyOrBlankSnapshotBlocksNothing() {
        engine.setSnapshot("[]")
        assertFalse(engine.hasAnyRules())
        assertNull(engine.blockingForPackage(IG, T))
        engine.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertTrue(engine.hasAnyRules())
        engine.setSnapshot("")
        assertFalse(engine.hasAnyRules())
    }

    @Test
    fun activeWindowBlocksItsPackageOnly() {
        engine.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertEquals("r1", engine.blockingForPackage(IG, T)?.id)
        assertEquals("SCHEDULE", engine.blockingForPackage(IG, T)?.reason)
        assertNull(engine.blockingForPackage("com.other", T))
        assertNull(engine.blockingForHost("instagram.com", T))
        assertNull(engine.blockingForPlatform("ig_reels", T, 0L))
    }

    @Test
    fun expiredAndFutureWindowsDoNotBlock() {
        val windows = "[${T - 2_000},${T - 1_000}],[${T + 1_000},${T + 2_000}]"
        engine.setSnapshot("[${entry(packages = q(IG), windows = windows)}]")
        assertNull(engine.blockingForPackage(IG, T))
        assertNotNull(engine.blockingForPackage(IG, T + 1_500))
        assertNull(engine.blockingForPackage(IG, T + 2_000), "end is exclusive")
        assertNotNull(engine.blockingForPackage(IG, T - 2_000), "start is inclusive")
    }

    @Test
    fun alwaysIgnoresWindows() {
        engine.setSnapshot("[${entry(packages = q(IG), always = true)}]")
        assertNotNull(engine.blockingForPackage(IG, T))
        assertNotNull(engine.blockingForPackage(IG, 0L))
    }

    @Test
    fun wildcardPlatformCoversEveryReelSurface() {
        engine.setSnapshot("[${entry(platforms = q("*"), windows = open())}]")
        assertNotNull(engine.blockingForPlatform("ig_reels", T, 0L))
        assertNotNull(engine.blockingForPlatform("yt_shorts", T, 0L))
        assertNull(engine.blockingForPackage(IG, T), "platform-only entry never bounces an app")
    }

    @Test
    fun reelMeterBlocksPlatformsOnlyOnceTheLimitIsReached() {
        val limit = 1_800_000L
        engine.setSnapshot(
            "[${entry(id = "daily_reel_limit", reason = "DAILY_LIMIT", platforms = q("*"), always = true, reelMs = limit)}]",
        )
        assertTrue(engine.hasReelMeter())
        assertNull(engine.blockingForPlatform("ig_reels", T, limit - 1))
        assertEquals("DAILY_LIMIT", engine.blockingForPlatform("ig_reels", T, limit)?.reason)
        assertNotNull(engine.blockingForPlatform("ig_reels", T, limit + 1))
        // A meter never applies to a package or a host, whatever it lists.
        engine.setSnapshot("[${entry(packages = q(IG), domains = q("instagram.com"), always = true, reelMs = limit)}]")
        assertNull(engine.blockingForPackage(IG, T))
        assertNull(engine.blockingForHost("instagram.com", T))
    }

    @Test
    fun allExceptInvertsWithinListedDimensionsOnly() {
        engine.setSnapshot("[${entry(mode = "ALL_EXCEPT", packages = q(IG), windows = open())}]")
        assertNotNull(engine.blockingForPackage("com.other", T))
        assertNull(engine.blockingForPackage(IG, T))
        assertNull(engine.blockingForHost("anything.com", T), "no domains listed → no host targeted")
        assertNull(engine.blockingForPlatform("ig_reels", T, 0L), "no platforms listed → none targeted")
    }

    @Test
    fun hostMatchesTheDomainAndItsSubdomains() {
        engine.setSnapshot("[${entry(domains = q("Instagram.com"), windows = open())}]")
        assertTrue(engine.hasHostRules())
        assertNotNull(engine.blockingForHost("instagram.com", T))
        assertNotNull(engine.blockingForHost("m.instagram.com", T))
        assertNull(engine.blockingForHost("notinstagram.com", T))
        assertNull(engine.blockingForHost("instagram.com.evil", T))
        assertNull(engine.blockingForHost("", T))
    }

    @Test
    fun strictOnlyNarrowsTheHostArmToOptedInRules() {
        // M8 closed EVO-030's documented website gap: `strict` used to cover
        // apps and reel feeds only, so a two-minute Pause opened a locked
        // rule's websites for free while its apps still cost an override.
        engine.setSnapshot(
            "[${entry(id = "loose", domains = q("instagram.com"), windows = open())}," +
                "${entry(id = "hard", strict = true, domains = q("x.com"), windows = open())}]",
        )
        assertTrue(engine.hasStrictHostRules())
        // Not paused: both hold.
        assertEquals("loose", engine.blockingForHost("instagram.com", T)?.id)
        assertEquals("hard", engine.blockingForHost("x.com", T)?.id)
        // Paused: only the opted-in one survives.
        assertNull(engine.blockingForHost("instagram.com", T, strictOnly = true))
        assertEquals("hard", engine.blockingForHost("x.com", T, strictOnly = true)?.id)
    }

    @Test
    fun hasStrictHostRulesIsFalseWithoutAnOptedInDomain() {
        // The gate has to be narrower than hasStrictRules, or a strict rule on
        // apps alone would open the browser arm during every Pause.
        engine.setSnapshot("[${entry(strict = true, packages = q(IG), windows = open())}]")
        assertTrue(engine.hasStrictRules())
        assertFalse(engine.hasStrictHostRules())
    }

    @Test
    fun strictOnlyFindsAStrictEntryBehindAnOlderNonStrictOne() {
        // The snapshot is ordered by createdAtMs and every arm returns the FIRST
        // covering entry, so an older loose rule masks a newer strict one. The
        // reel loop resolves strict on its OWN pass for exactly this reason: if
        // it trusted the first match's `strict` flag, a wall raised by the loose
        // rule would offer "Unblock for a while" and the grant that tap mints
        // would lift the LOCKED rule for free.
        engine.setSnapshot(
            "[${entry(id = "loose", platforms = q("ig_reels"), windows = open())}," +
                "${entry(id = "hard", strict = true, platforms = q("ig_reels"), windows = open())}]",
        )
        assertEquals("loose", engine.blockingForPlatform("ig_reels", T, 0L)?.id)
        assertEquals(
            "hard",
            engine.blockingForPlatform("ig_reels", T, 0L, strictOnly = true)?.id,
        )
        // Same shape for packages and hosts.
        engine.setSnapshot(
            "[${entry(id = "loose", packages = q(IG), domains = q("x.com"), windows = open())}," +
                "${entry(id = "hard", strict = true, packages = q(IG), domains = q("x.com"), windows = open())}]",
        )
        assertEquals("hard", engine.blockingForPackage(IG, T, strictOnly = true)?.id)
        assertEquals("hard", engine.blockingForHost("x.com", T, strictOnly = true)?.id)
    }

    @Test
    fun firstBlockingEntryWins() {
        engine.setSnapshot(
            "[${entry(id = "a", reason = "SCHEDULE", packages = q(IG), windows = open())}," +
                "${entry(id = "b", reason = "DAILY_LIMIT", packages = q(IG), windows = open())}]",
        )
        assertEquals("a", engine.blockingForPackage(IG, T)?.id)
    }

    @Test
    fun malformedJsonKeepsThePreviousSnapshot() {
        engine.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        engine.setSnapshot("{not json")
        engine.setSnapshot("[1, 2, 3]") // an array without objects clears — every row is skipped
        assertFalse(engine.hasAnyRules())
        engine.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        engine.setSnapshot("not even close")
        assertNotNull(engine.blockingForPackage(IG, T))
    }

    @Test
    fun entriesWithoutAnIdAreSkippedAndTheListIsCapped() {
        val many = (0 until 60).joinToString(",") { entry(id = "r$it", packages = q(IG), windows = open()) }
        engine.setSnapshot("[$many]")
        assertEquals("r0", engine.blockingForPackage(IG, T)?.id)
        engine.setSnapshot("""[{"reason":"SCHEDULE","packages":["$IG"],"always":true}]""")
        assertFalse(engine.hasAnyRules())
    }

    @Test
    fun theCapLeavesRoomForTheSyntheticDailyLimitEntry() {
        // Dart's own cap is 50 stored rules and it appends the daily-reel-limit
        // entry AFTER them, so a legitimate snapshot is 51 long. Capping at 50
        // truncated exactly that entry and silently stopped enforcing the
        // global Daily Limit while its UI still showed it set.
        val rules = (0 until 50).joinToString(",") { entry(id = "r$it", packages = q(IG), windows = open()) }
        val meter = entry(id = "daily_reel_limit", reason = "DAILY_LIMIT", platforms = q("*"), always = true, reelMs = 60_000)
        engine.setSnapshot("[$rules,$meter]")
        assertTrue(engine.hasReelMeter())
        assertEquals("daily_reel_limit", engine.blockingForPlatform("ig_reels", T, 60_000)?.id)
    }

    @Test
    fun aMeterOnlySnapshotNeverArmsThePackageArm() {
        // A user with zero rules but a global Daily Limit still has an entry, so
        // hasAnyRules() is true for them — the package arm runs above the
        // throttle on nearly every foreground event and must not be armed here.
        engine.setSnapshot("[${entry(id = "daily_reel_limit", reason = "DAILY_LIMIT", platforms = q("*"), always = true, reelMs = 60_000)}]")
        assertTrue(engine.hasAnyRules())
        assertFalse(engine.hasPackageRules())
        assertFalse(engine.hasHostRules())
        engine.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertTrue(engine.hasPackageRules())
    }

    @Test
    fun activeUntilNamesTheWindowCoveringNow() {
        // EVO-028: the wall's "Unlocks at …" line.
        engine.setSnapshot(
            "[${entry(packages = q(IG), windows = "[${T - 5_000},${T - 1_000}],[${T - 1_000},${T + 7_000}]")}]",
        )
        val hit = engine.blockingForPackage(IG, T)
        assertEquals(T + 7_000, hit?.activeUntil(T))

        // A meter entry has no edge to name.
        engine.setSnapshot("[${entry(platforms = q("*"), always = true, reelMs = 1)}]")
        assertEquals(0L, engine.blockingForPlatform("ig_reels", T, 5)?.activeUntil(T))
    }

    @Test
    fun strictOnlyMatchesEntriesTheUserOptedIn() {
        // EVO-030: the strict pass runs ABOVE the pause gate, so it must see
        // only the rules that asked for it — otherwise a Pause stops working.
        engine.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertFalse(engine.hasStrictRules())
        assertNull(engine.blockingForPackage(IG, T, strictOnly = true))
        assertNotNull(engine.blockingForPackage(IG, T))

        engine.setSnapshot("[${entry(strict = true, packages = q(IG), windows = open())}]")
        assertTrue(engine.hasStrictRules())
        assertFalse(engine.hasStrictPlatformRules())
        assertNotNull(engine.blockingForPackage(IG, T, strictOnly = true))

        engine.setSnapshot("[${entry(strict = true, platforms = q("ig_reels"), windows = open())}]")
        assertTrue(engine.hasStrictPlatformRules())
        assertNotNull(engine.blockingForPlatform("ig_reels", T, 0, strictOnly = true))
    }

    @Test
    fun strictPackageAndPlatformGatesAreExact() {
        // A strict rule built from websites alone must not arm the strict
        // package arm — it runs above the throttle on nearly every foreground
        // event and could never match.
        engine.setSnapshot("[${entry(strict = true, domains = q("x.com"), windows = open())}]")
        assertTrue(engine.hasStrictRules())
        assertFalse(engine.hasStrictPackageRules())
        assertFalse(engine.hasPlatformRules())

        engine.setSnapshot("[${entry(strict = true, packages = q(IG), windows = open())}]")
        assertTrue(engine.hasStrictPackageRules())
        assertFalse(engine.hasPlatformRules())

        // The meter's "*" is a platform: the detector arm has to run for it.
        engine.setSnapshot("[${entry(platforms = q("*"), always = true, reelMs = 1)}]")
        assertTrue(engine.hasPlatformRules())
        assertFalse(engine.hasStrictPackageRules())
    }

    @Test
    fun pendingBudgetGatesNameTheQueryEachNeeds() {
        // The watchdog pays for a UsageStats query only when a pending budget
        // of that kind exists: a time limit never needs the event log, an open
        // limit never needs the per-app totals.
        fun pending(id: String, usageMs: Long, opens: Int) =
            """{"id":"$id","reason":"DAILY_LIMIT","mode":"BLOCK","packages":[${q(IG)}],""" +
                """"domains":[],"platformIds":[],"windows":[${open()}],"always":false,""" +
                """"reelTimeLimitMs":0,"strict":false,"usageLimitMs":$usageMs,""" +
                """"openLimitCount":$opens,"spent":false}"""
        engine.setSnapshot("[${pending("t", 60_000L, 0)}]")
        assertTrue(engine.hasPendingLimits())
        assertTrue(engine.hasPendingUsageLimits())
        assertFalse(engine.hasPendingOpenLimits())

        engine.setSnapshot("[${pending("o", 0L, 5)}]")
        assertFalse(engine.hasPendingUsageLimits())
        assertTrue(engine.hasPendingOpenLimits())
    }

    @Test
    fun subdomainRuleIsAllocationFreeAndExact() {
        assertTrue(RuleEngine.isSubdomainOf("m.instagram.com", "instagram.com"))
        assertFalse(RuleEngine.isSubdomainOf("instagram.com", "instagram.com"))
        assertFalse(RuleEngine.isSubdomainOf("xinstagram.com", "instagram.com"))
    }

    private fun assertNull(value: Any?, reason: String) = assertNull(reason, value)

    private fun assertNotNull(value: Any?, reason: String) = assertNotNull(reason, value)

    private companion object {
        const val IG = "com.instagram.android"
        const val T = 1_756_800_000_000L

        fun q(s: String) = "\"$s\""
    }
}
