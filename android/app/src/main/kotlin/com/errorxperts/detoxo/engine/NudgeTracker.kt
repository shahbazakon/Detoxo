package com.errorxperts.detoxo.engine

/** What [NudgeTracker.tick] wants the overlay to do. */
sealed interface NudgeDecision {
    /** Nothing to do — leave the overlay exactly as it is. */
    data object None : NudgeDecision

    /** Take the card away (the user left, or the machine went quiet). */
    data object Dismiss : NudgeDecision

    /** Raise the card for [pkg], which has been foreground for [elapsedMs]. */
    data class Show(val pkg: String, val elapsedMs: Long, val thresholdMs: Long) : NudgeDecision
}

/**
 * Dwell state machine behind the soft nudge: the advisory middle setting
 * between "blocked" and "not blocked" — let the app open, and say something
 * once the user has been in it a while.
 *
 * Pure Kotlin (no Android imports): [tick] takes the wall-clock `now` and the
 * day key its owner already computes, and returns what the overlay should do.
 * Wall-clock rather than uptime because the threshold the user set is minutes
 * *of their day*.
 *
 * It is driven from EVERY accessibility event, not only the window changes,
 * carrying the service's latched foreground package: the identity of the stay
 * comes from WINDOW_STATE_CHANGED, but the heartbeat has to be dense or
 * [idleTimeoutMs] would fire on a user who is simply reading.
 *
 * Model
 *  - A SESSION is one continuous stay in one distracting app ([Session.pkg]).
 *    It ends after [idleTimeoutMs] with no event from that app, or the moment
 *    a different distracting app opens.
 *  - The WATERMARK ([Session.lastFiredThresholdMs]) is how far the nudges have
 *    got. It advances by exactly ONE [thresholdStepMs] per crossing, never to
 *    the elapsed total, so a phone left on a feed for 22 minutes gets one card
 *    on the user's next touch — not four queued ones.
 *  - A nudge is SHOWN at most [dailyCap] times per app per day; the tally rolls
 *    over with the `dayKey` its owner passes in.
 *
 * Event-driven by design: no ticker, no alarm. A session that goes completely
 * quiet does not advance, which is correct — no events means no interaction to
 * nudge about.
 *
 * ponytail: ceilings —
 *  (a) purely event-driven: a genuinely event-silent minute — a full-screen
 *      video that emits nothing at all — reads as leaving, and the stay
 *      restarts. Deliberately the safe direction, because the alternative
 *      (trusting a stale session) is a card claiming eight hours after a night
 *      on the charger. Upgrade path = fold into the Conscious accountant's
 *      1 Hz tick when that is already running, which can tell a sleeping
 *      screen from a quiet one;
 *  (b) the threshold is elapsed time inside ONE visit to ONE app, not
 *      cumulative daily use — two 4-minute visits never nudge; upgrade path =
 *      a daily accumulator, which is the daily limit and already exists, so
 *      point the user at that instead of building it twice;
 *  (c) [session] and [firedToday] are runtime-only and deliberately not
 *      persisted — a session that survives a process death is a session that
 *      nudges about an app the user closed an hour ago. The cost is that the
 *      daily cap resets with the service, which in practice outlives a day.
 *      A config push does NOT reset it: see [configure], which is why the
 *      tuning is mutable rather than constructor-final.
 */
class NudgeTracker(
    thresholdStepMs: Long = THRESHOLD_STEP_MS,
    idleTimeoutMs: Long = IDLE_TIMEOUT_MS,
    dailyCap: Int = DAILY_CAP,
) {
    /**
     * Mutable on purpose: [tick] runs on every accessibility event inside a
     * watched app, and an immutable session would allocate a copy per event
     * to advance one timestamp. [ContentCounter.onAppActivity] — the sibling
     * unthrottled per-event call — is likewise plain field math. Never escapes
     * this class, so the mutability is not observable.
     */
    private class Session(
        @JvmField val pkg: String,
        @JvmField var startedAtMs: Long,
        @JvmField var lastTickMs: Long,
        @JvmField var lastFiredThresholdMs: Long,
    )

    /**
     * Master switch, pushed from Dart. Off = [tick] is a hard no-op.
     *
     * Volatile because the config push arrives on the platform-channel thread
     * while [tick] reads from the accessibility callback thread.
     */
    @Volatile var enabled: Boolean = false
        private set

    /**
     * The apps that nudge: the catalog's `distracting` behaviour MINUS the
     * user's protected apps. The subtraction is the nudge's second privacy
     * anchor — see [configure].
     */
    @Volatile var distractingSet: Set<String> = emptySet()
        private set

    // Tuning. Coerced on write so a malformed push can never wedge the machine
    // (a zero step fires on every event; a zero timeout ends every session).
    private var thresholdStepMs: Long = thresholdStepMs.coerceAtLeast(MIN_STEP_MS)
    private var idleTimeoutMs: Long = idleTimeoutMs.coerceAtLeast(MIN_IDLE_MS)
    private var dailyCap: Int = dailyCap.coerceAtLeast(0)

    private var session: Session? = null

    /** App whose card is currently up; null = no card. Re-arms the machine. */
    private var currentNudgePkg: String? = null

    private var firedToday = HashMap<String, Int>()
    private var dayKey = ""

    /**
     * Apply pushed config **in place**.
     *
     * The day's per-app tally ([firedToday]) always survives this, and the live
     * session survives an unchanged step. That is the whole point: config
     * pushes are not rare. `pushSettings` reaches the engine on every app
     * resume and after every settings write — changing the theme used to be
     * enough — so rebuilding the tracker here silently handed the user a fresh
     * daily budget and a fresh dwell clock every time they opened Detoxo. The
     * ceiling this class documents is that the tally dies with the *process*,
     * not with a settings write.
     *
     * [packages] must already have the protected apps removed; the caller owns
     * that subtraction because it owns the protected set.
     */
    fun configure(
        enabled: Boolean,
        packages: Set<String>,
        thresholdStepMs: Long,
        dailyCap: Int,
        idleTimeoutMs: Long = IDLE_TIMEOUT_MS,
    ) {
        val nextStep = thresholdStepMs.coerceAtLeast(MIN_STEP_MS)
        // Only the step changes what a watermark MEANS, so only the step
        // invalidates a session in flight. A cap change takes effect on the
        // next crossing without disturbing the stay the user is in.
        if (nextStep != this.thresholdStepMs) session = null
        this.thresholdStepMs = nextStep
        this.idleTimeoutMs = idleTimeoutMs.coerceAtLeast(MIN_IDLE_MS)
        this.dailyCap = dailyCap.coerceAtLeast(0)
        this.distractingSet = packages
        this.enabled = enabled
        if (!enabled) reset()
    }

    /**
     * A window of [pkg] came to the foreground at [nowMs] (device-local
     * [dayKey]). `null` [pkg] is "some app we do not track" and is treated the
     * same way as a non-distracting one.
     */
    fun tick(pkg: String?, nowMs: Long, dayKey: String): NudgeDecision {
        if (!enabled) return NudgeDecision.None
        rollDay(dayKey)

        // Measured from lastTickMs, not from the session start, and applied
        // whatever is foreground: a minute with no event from the app — the
        // user switched away, took a call, put the phone down — is not a stay.
        // Checking it here rather than only on the leaving branch is what stops
        // a phone locked overnight inside Instagram from waking up to a
        // "480 minutes" card.
        // A negative delta means the wall clock moved backwards (NTP
        // correction, the user setting the date). The stay can no longer be
        // measured, so it ends rather than wedging: `elapsed` would go negative
        // and suppress every nudge for that app until the clock caught up.
        session?.let {
            val sinceTick = nowMs - it.lastTickMs
            if (sinceTick > idleTimeoutMs || sinceTick < 0L) session = null
        }

        val distracting = if (pkg != null && pkg in distractingSet) pkg else null
        var fired = false

        if (distracting != null) {
            val s = session
            if (s == null || s.pkg != distracting) {
                // A different app — fresh session, watermark back at zero.
                session = Session(distracting, nowMs, nowMs, 0L)
            } else {
                val elapsed = nowMs - s.startedAtMs
                val next = s.lastFiredThresholdMs + thresholdStepMs
                if (elapsed >= next) {
                    fired = true
                    s.lastFiredThresholdMs = next // ONE step, never the total
                }
                s.lastTickMs = nowMs
            }
        }

        if (!fired) {
            // Left the app the card belongs to: take it away. Staying put does
            // NOT — every window change inside the app would otherwise kill a
            // card a second after it appeared; its own timer owns that.
            val showing = currentNudgePkg
            if (showing == null || showing == distracting) return NudgeDecision.None
            currentNudgePkg = null
            return NudgeDecision.Dismiss
        }
        if (distracting == null) return NudgeDecision.None // unreachable; keeps the type honest
        if (currentNudgePkg == distracting) return NudgeDecision.None // already nudging this app
        val seen = firedToday[distracting] ?: 0
        if (seen >= dailyCap) return NudgeDecision.None // a card every 5 min forever is noise
        firedToday[distracting] = seen + 1
        currentNudgePkg = distracting
        val s = session ?: return NudgeDecision.None
        return NudgeDecision.Show(distracting, nowMs - s.startedAtMs, s.lastFiredThresholdMs)
    }

    /**
     * The card went away (auto-dismiss, or the user closed it) while the user
     * stayed put. Re-arms the machine so the next threshold nudges again —
     * without this a dismissed nudge never returns.
     */
    fun onDismissed() {
        currentNudgePkg = null
    }

    /** Config changed or the engine reloaded: forget the live session. */
    fun reset() {
        session = null
        currentNudgePkg = null
    }

    private fun rollDay(key: String) {
        if (key == dayKey) return
        dayKey = key
        firedToday = HashMap()
    }

    companion object {
        /** Nudge every 5 minutes of continuous use (`xj.d`). */
        const val THRESHOLD_STEP_MS = 300_000L

        /** A minute away from the app ends the session (`xj.d`). */
        const val IDLE_TIMEOUT_MS = 60_000L

        /** Nudges per app per day; the fifth card of an evening is wallpaper. */
        const val DAILY_CAP = 4

        /** Defensive floors. `ConfigStore` clamps harder; these stop a direct
         *  caller wedging the machine (a zero step fires on every event, a zero
         *  timeout ends every session). */
        private const val MIN_STEP_MS = 1_000L
        private const val MIN_IDLE_MS = 1_000L
    }
}
