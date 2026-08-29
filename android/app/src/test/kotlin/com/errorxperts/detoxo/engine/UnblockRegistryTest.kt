package com.errorxperts.detoxo.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [UnblockRegistry] against hand-built payloads in the Dart
 * `TemporaryUnblock` wire shape. `org.json` is the real artifact on the test
 * classpath (see build.gradle.kts), so the parse itself is exercised here.
 *
 * Both clocks are arguments, which is the whole reason this class is testable
 * where [WebBlockEngine] is not — and it lets the EVO-048 regression guard below
 * move the wall clock without touching the device.
 */
class UnblockRegistryTest {

    private val registry = UnblockRegistry()

    /** An arbitrary "now": a wall stamp and an unrelated monotonic reading. */
    private val wall = 1_756_742_400_000L
    private val elapsed = 90_000L

    private fun grant(type: String, id: String, endMs: Long) =
        """{"targetType":"$type","targetId":"$id","endMs":$endMs}"""

    private fun push(vararg rows: String, atWall: Long = wall, atElapsed: Long = elapsed) =
        registry.setGrants("[${rows.joinToString(",")}]", atWall, atElapsed)

    @Test
    fun blankClearsAndEmptyGrantsNothing() {
        push(grant(UnblockRegistry.TYPE_APP, IG, wall + 60_000))
        assertTrue(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed))
        registry.setGrants("", wall, elapsed)
        assertFalse(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed))
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_APP, IG, elapsed))
    }

    @Test
    fun malformedPayloadKeepsThePreviousGrants() {
        push(grant(UnblockRegistry.TYPE_APP, IG, wall + 60_000))
        registry.setGrants("{not an array}", wall, elapsed)
        assertTrue(
            "a bad push must never unlock or re-lock a phone",
            registry.isUnblocked(UnblockRegistry.TYPE_APP, IG, elapsed),
        )
    }

    @Test
    fun anActiveGrantLiftsItsOwnTargetOnly() {
        push(grant(UnblockRegistry.TYPE_APP, IG, wall + 60_000))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_APP, IG, elapsed))
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_APP, "com.other", elapsed))
        // Types never cross: an APP grant is not a REEL grant for the same id.
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_REEL, IG, elapsed))
        assertFalse(registry.hasAny(UnblockRegistry.TYPE_REEL, elapsed))
    }

    @Test
    fun aGrantExpiresOnTheMonotonicClock() {
        push(grant(UnblockRegistry.TYPE_REEL, "ig_reels", wall + 60_000))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_REEL, "ig_reels", elapsed + 59_999))
        assertFalse(
            "end is exclusive",
            registry.isUnblocked(UnblockRegistry.TYPE_REEL, "ig_reels", elapsed + 60_000),
        )
    }

    @Test
    fun aDeadlineAlreadyPastIsDroppedAtParse() {
        push(
            grant(UnblockRegistry.TYPE_APP, IG, wall - 1),
            grant(UnblockRegistry.TYPE_APP, "com.live", wall + 60_000),
        )
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_APP, IG, elapsed))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_APP, "com.live", elapsed))
    }

    @Test
    fun movingTheWallClockBackDoesNotExtendAGrant() {
        // EVO-048 regression guard. The grant is minted 10 minutes out, then the
        // user rolls the device clock back an hour in Settings. `isUnblocked`
        // takes elapsedRealtime, which the Settings clock cannot move, so the
        // grant still lapses on time. Comparing System.currentTimeMillis here
        // would hold it open for 70 minutes.
        push(grant(UnblockRegistry.TYPE_WEBSITE, "youtube.com", wall + 600_000))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "youtube.com", elapsed))
        assertFalse(
            registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "youtube.com", elapsed + 600_000),
        )
    }

    @Test
    fun aWebsiteGrantCoversSubdomainsButNotSiblingsOrParents() {
        push(grant(UnblockRegistry.TYPE_WEBSITE, "youtube.com", wall + 60_000))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "youtube.com", elapsed))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "m.youtube.com", elapsed))
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "notyoutube.com", elapsed))
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "youtu.be", elapsed))
        // The reverse direction must NOT match: a grant on the subdomain does
        // not open the parent.
        registry.setGrants(
            "[${grant(UnblockRegistry.TYPE_WEBSITE, "m.youtube.com", wall + 60_000)}]",
            wall,
            elapsed,
        )
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "youtube.com", elapsed))
    }

    @Test
    fun hostsAreLowerCasedAtParseButPackagesAreNot() {
        push(
            grant(UnblockRegistry.TYPE_WEBSITE, "YouTube.COM", wall + 60_000),
            grant(UnblockRegistry.TYPE_APP, "com.Mixed.Case", wall + 60_000),
        )
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_WEBSITE, "youtube.com", elapsed))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_APP, "com.Mixed.Case", elapsed))
    }

    @Test
    fun unknownTypesAndEmptyIdsAreSkipped() {
        push(
            """{"targetType":"GALAXY","targetId":"x","endMs":${wall + 60_000}}""",
            """{"targetType":"APP","targetId":"  ","endMs":${wall + 60_000}}""",
            """{"targetType":"APP","endMs":${wall + 60_000}}""",
        )
        assertFalse(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed))
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_APP, "x", elapsed))
        assertFalse(registry.isUnblocked("GALAXY", "x", elapsed))
    }

    @Test
    fun theListIsCappedSoTheScanStaysBounded() {
        val rows = (0 until UnblockRegistry.MAX_GRANTS + 10)
            .map { grant(UnblockRegistry.TYPE_APP, "com.app$it", wall + 60_000) }
        registry.setGrants("[${rows.joinToString(",")}]", wall, elapsed)
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_APP, "com.app0", elapsed))
        assertTrue(
            registry.isUnblocked(
                UnblockRegistry.TYPE_APP,
                "com.app${UnblockRegistry.MAX_GRANTS - 1}",
                elapsed,
            ),
        )
        assertFalse(
            registry.isUnblocked(
                UnblockRegistry.TYPE_APP,
                "com.app${UnblockRegistry.MAX_GRANTS}",
                elapsed,
            ),
        )
    }

    @Test
    fun anUnchangedPayloadIsNotReparsed() {
        val json = "[${grant(UnblockRegistry.TYPE_APP, IG, wall + 60_000)}]"
        registry.setGrants(json, wall, elapsed)
        // Re-pushing the identical string 10 minutes later must NOT re-anchor the
        // deadline to the newer elapsed reading — that would let a resume-driven
        // re-push renew a grant indefinitely.
        registry.setGrants(json, wall + 600_000, elapsed + 600_000)
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_APP, IG, elapsed + 60_000))
    }

    @Test
    fun theHotPathGateExpiresItselfWithoutAPush() {
        push(grant(UnblockRegistry.TYPE_APP, IG, wall + 60_000))
        assertTrue(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed + 59_999))
        // No second push: the grant lapsing while Flutter is dead is exactly the
        // case native expiry exists for, and a gate that stayed true made every
        // later event pay a full scan for the life of the process.
        assertFalse(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed + 60_000))
    }

    @Test
    fun theGateTracksTheFurthestDeadlineOfItsOwnType() {
        push(
            grant(UnblockRegistry.TYPE_APP, IG, wall + 60_000),
            grant(UnblockRegistry.TYPE_APP, "com.other", wall + 600_000),
            grant(UnblockRegistry.TYPE_REEL, "ig_reels", wall + 30_000),
        )
        // The nearer APP grant lapsing must not close the gate on the later one.
        assertTrue(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed + 60_000))
        assertFalse(registry.isUnblocked(UnblockRegistry.TYPE_APP, IG, elapsed + 60_000))
        assertTrue(registry.isUnblocked(UnblockRegistry.TYPE_APP, "com.other", elapsed + 60_000))
        // …and types keep their own deadlines.
        assertFalse(registry.hasAny(UnblockRegistry.TYPE_REEL, elapsed + 30_000))
        assertFalse(registry.hasAny(UnblockRegistry.TYPE_APP, elapsed + 600_000))
    }

    private companion object {
        const val IG = "com.instagram.android"
    }
}
