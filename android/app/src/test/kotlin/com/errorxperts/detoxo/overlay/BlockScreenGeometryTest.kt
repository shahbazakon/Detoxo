package com.errorxperts.detoxo.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the wall's pure half: window flags, the strip-width formula at both SDK
 * branches, the plan-label mapping (the wire token `CURIOUS` must never reach
 * a screen), and the payload sanitiser (EVO-018). Window lifecycle needs a
 * device — see the device-sanity list in docs/code_docs/25-block-screen.md.
 */
class BlockScreenGeometryTest {

    @Test
    fun windowFlagsAre808() {
        assertEquals(808, overlayFlags())
    }

    @Test
    fun stripWidthFollowsTheGestureInsetOnApi30() {
        assertEquals(48, stripWidthPx(30, 24, 32, 2f))
        assertEquals(36, stripWidthPx(34, 24, 0, 3f))
    }

    @Test
    fun stripWidthIs50dpBelowApi30() {
        assertEquals(125, stripWidthPx(29, 24, 32, 2.5f))
        assertEquals(100, stripWidthPx(24, 0, 0, 2f))
    }

    @Test
    fun primaryButtonTextFollowsItsFill() {
        val navy = 0xFF0B1326.toInt()
        val white = 0xFFFFFFFF.toInt()
        assertEquals(navy, onColorFor(0xFF12A594.toInt())) // light accent: navy 6.0:1, white 3.1:1
        assertEquals(navy, onColorFor(0xFF44E2CD.toInt())) // dark accent
        assertEquals(navy, onColorFor(0xFF30A46C.toInt())) // usage band 0 (green)
        assertEquals(white, onColorFor(0xFFC63A3E.toInt())) // usage band 350+ (deep red): navy 3.6:1
        assertTrue(contrastRatio(navy, 0xFF12A594.toInt()) >= 4.5)
        assertTrue(contrastRatio(white, 0xFFC63A3E.toInt()) >= 4.5)
        assertEquals(21.0, contrastRatio(navy.and(0xFF000000.toInt()), white), 0.01) // black on white
    }

    @Test
    fun textBlockClearsTheButtonColumn() {
        // Room to spare: the block sits 34 % down.
        assertEquals(680f, wallTextTop(2000, 400, 300, 32, 96), 0.001f)
        // A tall block (large font scale) is pulled up clear of the column.
        assertEquals(468f, wallTextTop(2000, 1200, 300, 32, 96), 0.001f)
        // Never above the cutout / status-bar guard.
        assertEquals(96f, wallTextTop(2000, 1900, 300, 32, 96), 0.001f)
    }

    @Test
    fun planLabelsAreTheUserFacingNames() {
        assertEquals("Conscious", planLabel("CURIOUS", 1))
        assertEquals("One Reel", planLabel("ONE_REEL", 1))
        assertEquals("Unblock", planLabel("ONE_REEL", 5))
        assertEquals("Block All", planLabel("BLOCK_ALL", 1))
        assertEquals("Paused", planLabel("PAUSED", 1))
        assertEquals("", planLabel("", 1))
        assertEquals("", planLabel("weird", 1))
    }

    @Test
    fun theWireTokenNeverReachesALabel() {
        for (token in listOf("CURIOUS", "ONE_REEL", "BLOCK_ALL", "PAUSED", "")) {
            for (allowance in listOf(1, 5)) {
                assertFalse(planLabel(token, allowance).contains("curious", ignoreCase = true))
            }
        }
    }

    @Test
    fun adultPayloadIsNeverNamedAndNeverUnblockable() {
        val p = BlockScreenPayload.fromMap(
            mapOf(
                "referenceType" to "WEBSITE",
                "referenceId" to "example.test",
                "displayName" to "example.test",
                "appLabel" to "Chrome",
                "blockReason" to "ADULT",
                "plan" to "BLOCK_ALL",
                "offersUnblock" to true,
            ),
        )!!.sanitised()
        assertEquals("", p.displayName)
        assertEquals("", p.referenceId)
        assertEquals("Chrome", p.appLabel)
        assertFalse(p.offersUnblock)
        assertEquals("", p.plan)
    }

    @Test
    fun onlyAPlanBlockCarriesAPlanChip() {
        val app = BlockScreenPayload.fromMap(
            mapOf("referenceType" to "APP", "blockReason" to "APP_BLOCK", "plan" to "BLOCK_ALL"),
        )!!.sanitised()
        assertEquals("", app.plan)
        val reel = BlockScreenPayload.fromMap(
            mapOf("referenceType" to "REEL", "blockReason" to "PLAN", "plan" to "CURIOUS", "bankMs" to 0),
        )!!.sanitised()
        assertEquals("CURIOUS", reel.plan)
        assertEquals(0L, reel.bankMs)
        assertEquals(-1, reel.todayCount)
        assertEquals(-1, reel.opensToday)
        assertEquals("", reel.packageName)
        assertTrue(reel.offersOpenApp)
    }

    @Test
    fun payloadNeedsAReferenceTypeAndAReason() {
        assertNull(BlockScreenPayload.fromMap(null))
        assertNull(BlockScreenPayload.fromMap(emptyMap<String, Any>()))
        assertNull(BlockScreenPayload.fromMap(mapOf("referenceType" to "REEL")))
    }

    @Test
    fun styleSpecDefaultsKeepTheWallOn() {
        // org.json is a stub on the JVM test classpath, so only the defaults
        // (the path an absent / unparsable style takes) are pinned here; the
        // parse itself is exercised on-device like WidgetStyleSpec's.
        val defaults = BlockScreenStyleSpec()
        assertTrue(defaults.enabled)
        assertTrue(defaults.showCount)
        assertTrue(defaults.showOpens)
        assertFalse(defaults.accentByUsage)
        assertEquals(5, defaults.backDelaySec)
        assertEquals("SYSTEM", defaults.theme)
        assertEquals("GLASS_DARK", defaults.background)
        assertEquals(defaults, BlockScreenStyleSpec.fromJson(null))
        assertEquals(defaults, BlockScreenStyleSpec.fromJson(""))
    }
}
