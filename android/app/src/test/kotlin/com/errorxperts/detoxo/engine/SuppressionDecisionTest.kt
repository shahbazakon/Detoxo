package com.errorxperts.detoxo.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [SuppressionDecision] — the whole of notification suppression's
 * branching — against a real [RuleEngine] built from the Dart wire shape.
 *
 * The listener and the accessibility service around it are Android classes and
 * cannot run here; this is the runnable check that the decision itself is
 * right, and above all that a protected app is never silenced.
 */
class SuppressionDecisionTest {

    private val rules = RuleEngine()

    /** The call under test, with the ordinary case as defaults. */
    private fun suppress(
        pkg: String,
        protectedPkgs: Set<String> = emptySet(),
        blockedApps: Set<String> = emptySet(),
        paused: Boolean = false,
        now: Long = T,
    ) = SuppressionDecision.shouldSuppress(
        pkg = pkg,
        ownPkg = OWN,
        protectedPkgs = protectedPkgs,
        blockedApps = blockedApps,
        rules = rules,
        now = now,
        paused = paused,
    )

    @Test
    fun ownNotificationsAreNeverSuppressed() {
        // Detoxo's "Protection stopped" alert is the user's only signal that
        // the engine died — cancelling it would hide the failure.
        rules.setSnapshot("[${entry(packages = q(OWN), windows = open())}]")
        assertFalse(suppress(OWN, blockedApps = setOf(OWN)))
    }

    @Test
    fun protectedAppIsNeverSuppressedEvenWhenAlsoBlocked() {
        // THE privacy assertion: protection outranks a lock AND an active rule.
        rules.setSnapshot("[${entry(packages = q(BANK), windows = open())}]")
        assertFalse(
            suppress(BANK, protectedPkgs = setOf(BANK), blockedApps = setOf(BANK)),
        )
        // …including while paused, and with a strict rule naming it.
        rules.setSnapshot(
            "[${entry(packages = q(BANK), windows = open(), strict = true)}]",
        )
        assertFalse(
            suppress(BANK, protectedPkgs = setOf(BANK), paused = true),
        )
    }

    @Test
    fun appBlockerLockSuppressesThroughAPause() {
        // Mirrors the service: whole-app locks sit ABOVE the pause gate, since
        // the App Blocker presents them as unconditional.
        rules.setSnapshot("[]")
        assertTrue(suppress(IG, blockedApps = setOf(IG)))
        assertTrue(suppress(IG, blockedApps = setOf(IG), paused = true))
    }

    @Test
    fun activeRuleWindowSuppressesButAClosedOneDoesNot() {
        rules.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertTrue(suppress(IG))
        // The staleness case a pushed set could not cover: the window closes
        // with no user action, and the very next notification gets through.
        assertFalse(suppress(IG, now = T + 2_000))
    }

    @Test
    fun aPauseLiftsAnOrdinaryRuleButNotAStrictOne() {
        rules.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertFalse(suppress(IG, paused = true))
        rules.setSnapshot(
            "[${entry(packages = q(IG), windows = open(), strict = true)}]",
        )
        assertTrue(suppress(IG, paused = true))
    }

    @Test
    fun unrelatedPackagesAreNeverSuppressed() {
        rules.setSnapshot("[${entry(packages = q(IG), windows = open())}]")
        assertFalse(suppress("com.some.messenger"))
        assertFalse(suppress("com.some.messenger", blockedApps = setOf(IG)))
    }

    @Test
    fun aReelMeterEntryNeverSuppressesAnApp() {
        // A global Daily Limit is a platform meter, not an app-level block:
        // the app stays openable, so its notifications must keep arriving.
        rules.setSnapshot(
            "[${entry(id = "daily_reel_limit", platforms = q("*"), always = true, reelMs = 1)}]",
        )
        assertFalse(suppress(IG))
    }

    // ── EVO-038: block the feed, never the person ───────────────────────────

    @Test
    fun personToPersonAndTimeCriticalCategoriesAreAlwaysAllowed() {
        // The exact string values of Notification.CATEGORY_* — frozen API, and
        // mirrored here rather than imported (see the KDoc on ALWAYS_ALLOWED).
        for (c in listOf("msg", "call", "email", "alarm", "reminder", "event")) {
            assertTrue(c, SuppressionDecision.isAlwaysAllowed(c))
        }
    }

    @Test
    fun feedAndPromoCategoriesAreNotAllowedThrough() {
        // "social" is what a re-engagement / new-content notification uses —
        // the whole reason this feature exists. It must NOT be exempt.
        for (c in listOf("social", "promo", "recommendation", "status", "")) {
            assertFalse(c, SuppressionDecision.isAlwaysAllowed(c))
        }
    }

    @Test
    fun anUncategorisedNotificationIsNotExempt() {
        // Absent category = silenced. The safe default for the feature: an app
        // that sets no category cannot opt itself out of a block by omission.
        assertFalse(SuppressionDecision.isAlwaysAllowed(null))
    }

    private fun entry(
        id: String = "r1",
        strict: Boolean = false,
        packages: String = "",
        platforms: String = "",
        windows: String = "",
        always: Boolean = false,
        reelMs: Long = 0L,
    ) = """{"id":"$id","reason":"SCHEDULE","mode":"BLOCK","packages":[$packages],""" +
        """"domains":[],"platformIds":[$platforms],"windows":[$windows],""" +
        """"always":$always,"reelTimeLimitMs":$reelMs,"strict":$strict}"""

    private fun open() = "[${T - 1_000},${T + 1_000}]"

    private companion object {
        const val OWN = "com.errorxperts.detoxo"
        const val IG = "com.instagram.android"
        const val BANK = "com.google.android.apps.nbu.paisa.user"
        const val T = 1_756_800_000_000L

        fun q(s: String) = "\"$s\""
    }
}
