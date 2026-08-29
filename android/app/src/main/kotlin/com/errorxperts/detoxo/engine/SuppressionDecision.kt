package com.errorxperts.detoxo.engine

/**
 * THE decision behind notification suppression: may [pkg]'s notifications be
 * cancelled right now?
 *
 * Lives here, apart from the listener, for two reasons. It is Android-free
 * (like [RuleEngine] and [ReelTracker]) so the branching runs on the JVM — a
 * `NotificationListenerService` subclass never can. And it is derived, never
 * stored: the answer is computed per notification from the engine's live state,
 * so it cannot go stale at a schedule boundary the way a pushed set would.
 *
 * MIRROR CONTRACT with the block arms in `DetoxoAccessibilityService`
 * (`onAccessibilityEvent`, the App Blocker / strict / rules arms): an app is
 * silenced exactly when opening it would bounce the user HOME. Change the order
 * or the pause placement there → change it here, or suppression drifts away
 * from blocking and starts silencing apps the user can still open.
 */
object SuppressionDecision {

    /**
     * @param blockedApps the App Blocker's whole-app locks (`ConfigStore.blockedAppPackages`).
     * @param paused a live Pause window covers [now] — narrows rules to strict entries.
     */
    fun shouldSuppress(
        pkg: String,
        ownPkg: String,
        protectedPkgs: Set<String>,
        blockedApps: Set<String>,
        rules: RuleEngine,
        now: Long,
        paused: Boolean,
    ): Boolean {
        // Belt and braces: Detoxo's own protection / watchdog notifications are
        // the user's only signal that the engine died. Never cancel them.
        if (pkg == ownPkg) return false

        // The privacy guard, and it wins over everything below — a notification
        // listener sees far more of the device than the accessibility service
        // does, so a protected app (banking, UPI, password manager) is refused
        // here even when it is ALSO locked or named by an active rule.
        if (pkg in protectedPkgs) return false

        // App Blocker locks sit ABOVE the pause gate, exactly as in the service:
        // the UI presents a lock as unconditional, so a Pause taken for reels
        // must not quietly start letting a locked app notify again.
        if (pkg in blockedApps) return true

        // Rules. Below the pause gate, except for strict entries (EVO-030) —
        // the user opted those in precisely so a Pause cannot lift them.
        return rules.blockingForPackage(pkg, now, strictOnly = paused) != null
    }

    /**
     * EVO-038 — the product rule, applied to notifications: Detoxo blocks the
     * *feed*, not the app. A locked Instagram must stop advertising reels; it
     * must not swallow a message from a person or a call.
     *
     * [category] is `Notification.category` — a fixed Android constant naming
     * the KIND of notification, chosen by the sending app from a closed set. It
     * carries no user content, which is what makes this affordable: the
     * alternative, per-channel filtering, needs an app-defined `channelId` plus
     * a UI for the user to classify each one.
     *
     * Anything person-to-person or time-critical is always allowed through.
     * Everything else from a blocked app — the feed, the "3 new reels", the
     * re-engagement nudge, and any notification that sets no category at all —
     * is silenced.
     */
    fun isAlwaysAllowed(category: String?): Boolean =
        category != null && category in ALWAYS_ALLOWED

    // Deliberate mirrors of android.app.Notification.CATEGORY_*, NOT a missed
    // dedupe: importing that class would drag the Android framework onto this
    // object's JVM test classpath, which is the whole reason the decision lives
    // here rather than in the listener (the RuleEngine.REASON_* precedent).
    // These constants are frozen API — their string values cannot change.
    private val ALWAYS_ALLOWED = setOf(
        "msg", // CATEGORY_MESSAGE — a person wrote to you
        "call", // CATEGORY_CALL — an incoming call
        "email", // CATEGORY_EMAIL
        "alarm", // CATEGORY_ALARM
        "reminder", // CATEGORY_REMINDER
        "event", // CATEGORY_EVENT — a calendar entry starting
    )
}
