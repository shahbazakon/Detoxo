package com.errorxperts.detoxo.overlay

import com.errorxperts.detoxo.channels.CommandHandler

/**
 * When a block raises the wall, and when the wall may ignore the Appearance
 * switch. One object so the service's trigger sites and the overlay's own
 * gate can never disagree.
 *
 * A reel block walls for exactly two reasons: the user chose the
 * `BLOCK_SCREEN` mode in "When a reel is detected", or the block is
 * [forced] — something the user committed to in advance (a spent daily
 * limit, a schedule window, a drained Conscious bank — EVO-054/055).
 *
 * `BLOCK_SCREEN` is a wall policy, not a navigation: the detectors' config
 * lists only `PRESS_BACK` / `KILL_APP`, so `resolveBlockMode` still yields a
 * back press. The wall accompanies that navigation, never replaces it.
 */
object WallPolicy {
    const val MODE_BLOCK_SCREEN = "BLOCK_SCREEN"

    /**
     * A block the user cannot be surprised by: a spent daily limit, a schedule,
     * or the Conscious bank hitting zero. These wall in every mode and skip
     * the Appearance switch — only the overlay grant can stop them.
     */
    fun forced(reason: String, plan: String, bankMs: Long): Boolean =
        reason == BlockScreenPayload.REASON_DAILY_LIMIT ||
            reason == BlockScreenPayload.REASON_SCHEDULE ||
            (reason == BlockScreenPayload.REASON_PLAN &&
                plan == CommandHandler.PLAN_CONSCIOUS && bankMs == 0L)

    fun forced(p: BlockScreenPayload): Boolean = forced(p.blockReason, p.plan, p.bankMs)

    /**
     * A reel block's wall. [chosenMode] is the user's stored default, [navMode]
     * the resolved navigation: a `NONE` navigation never gets a wall — one over
     * a still-playing reel is a trap.
     */
    fun reelWall(chosenMode: String, navMode: String, forced: Boolean): Boolean =
        navMode != "NONE" && (chosenMode == MODE_BLOCK_SCREEN || forced)

    /**
     * Whether [p] may show with `BlockScreenStyleSpec.enabled == false`: a
     * forced block always, and a reel wall in the mode the user picked it
     * for — the switch then governs app and website walls only. Decided here,
     * from the payload, so a style rebuild of a standing wall reaches the same
     * answer as the raise did.
     */
    fun bypassesSwitch(p: BlockScreenPayload, chosenMode: String): Boolean =
        forced(p) ||
            (p.referenceType == BlockScreenPayload.TYPE_REEL && chosenMode == MODE_BLOCK_SCREEN)
}
