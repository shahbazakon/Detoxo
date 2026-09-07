package com.errorxperts.detoxo.overlay

import com.errorxperts.detoxo.channels.CommandHandler
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WallPolicyTest {
    private val blockScreen = WallPolicy.MODE_BLOCK_SCREEN
    private val planReason = BlockScreenPayload.REASON_PLAN

    private fun reel(reason: String = planReason, plan: String = "BLOCK_ALL", bankMs: Long = -1L) =
        BlockScreenPayload(
            referenceType = BlockScreenPayload.TYPE_REEL, referenceId = "ig_reels",
            displayName = "Instagram Reels", blockReason = reason, plan = plan, bankMs = bankMs,
        )

    private fun app(reason: String = BlockScreenPayload.REASON_APP_BLOCK) =
        BlockScreenPayload(
            referenceType = BlockScreenPayload.TYPE_APP, referenceId = "com.x",
            displayName = "X", blockReason = reason,
        )

    @Test
    fun blockScreenModeRaisesTheWallOtherModesDoNot() {
        assertTrue(WallPolicy.reelWall(blockScreen, "PRESS_BACK", forced = false))
        assertFalse(WallPolicy.reelWall("PRESS_BACK", "PRESS_BACK", forced = false))
        assertFalse(WallPolicy.reelWall("KILL_APP", "KILL_APP", forced = false))
    }

    @Test
    fun aForcedBlockWallsInAnyModeButNeverOverANoneNavigation() {
        assertTrue(WallPolicy.reelWall("PRESS_BACK", "PRESS_BACK", forced = true))
        assertFalse(WallPolicy.reelWall(blockScreen, "NONE", forced = true))
    }

    @Test
    fun forcedMeansALimitAScheduleOrADrainedConsciousBank() {
        assertTrue(WallPolicy.forced(BlockScreenPayload.REASON_DAILY_LIMIT, "BLOCK_ALL", -1L))
        assertTrue(WallPolicy.forced(BlockScreenPayload.REASON_SCHEDULE, "BLOCK_ALL", -1L))
        assertTrue(WallPolicy.forced(planReason,CommandHandler.PLAN_CONSCIOUS, 0L))
        // A bank with time left, or a plan that has no bank, is an ordinary block.
        assertFalse(WallPolicy.forced(planReason,CommandHandler.PLAN_CONSCIOUS, 30_000L))
        assertFalse(WallPolicy.forced(planReason,"BLOCK_ALL", 0L))
        assertFalse(WallPolicy.forced(BlockScreenPayload.REASON_APP_BLOCK, "BLOCK_ALL", -1L))
    }

    @Test
    fun theAppearanceSwitchIsSkippedByForcedWallsAndByTheChosenReelMode() {
        assertTrue(WallPolicy.bypassesSwitch(reel(), blockScreen))
        assertFalse(WallPolicy.bypassesSwitch(reel(), "PRESS_BACK"))
        assertTrue(WallPolicy.bypassesSwitch(reel(BlockScreenPayload.REASON_DAILY_LIMIT), "PRESS_BACK"))
        assertTrue(WallPolicy.bypassesSwitch(app(BlockScreenPayload.REASON_DAILY_LIMIT), "PRESS_BACK"))
        // App and website walls still answer to the switch in Block screen mode.
        assertFalse(WallPolicy.bypassesSwitch(app(), blockScreen))
    }
}
