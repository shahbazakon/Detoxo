package com.errorxperts.detoxo.notifications

import android.content.ComponentName
import android.content.Context
import android.os.Process
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.errorxperts.detoxo.accessibility.DetoxoAccessibilityService
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.SuppressionDecision

/**
 * Cancels notifications from apps that are blocked right now, so a locked app
 * cannot advertise itself back into the user's attention.
 *
 * ## Privacy — the rules, in code, not just in intent
 *
 * 1. Protected apps (banking, UPI, password managers) are refused inside
 *    [SuppressionDecision], above every other check.
 * 2. [onNotificationPosted] reads `packageName`, `key`, `user` and the
 *    notification's **category** — a fixed Android constant naming the *kind*
 *    of notification (EVO-038). It must never read `sbn.notification.extras`,
 *    which is where the title, text, sender and images live. Nothing is
 *    stored, logged or transmitted; a cancelled notification is never read,
 *    modified or re-posted.
 *
 * ## Binding follows the switch
 *
 * The system binds every listener enabled in `Settings.Secure` on boot and
 * after a package replace, and a user can grant notification access from the
 * permission funnel without ever switching the feature on. [onListenerConnected]
 * is therefore the only place that can hold the "off means Detoxo receives
 * nothing" guarantee — [syncBinding] alone cannot, because it is only reached
 * on a change of the pushed flag.
 */
class DetoxoNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        // Re-assert the user's switch on every connect. Without this an
        // ON→OFF→reboot leaves the listener bound for the rest of the boot
        // cycle, and a funnel-only grant binds it though the user never opted
        // in — in both cases the disclosure's "Detoxo stops receiving
        // notifications entirely" would be false.
        if (!ConfigStore(this).suppressNotifications) {
            instance = null
            requestUnbind()
            return
        }
        instance = this
        Log.i(TAG, "listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // Called for EVERY notification from EVERY app on the device, in
        // bursts. Everything below is metadata reads plus two volatile reads
        // and a bounded (<=51 entry) in-memory scan — no Dart round-trip, no
        // disk. Never add work here.
        try {
            val posted = sbn ?: return
            val pkg = posted.packageName ?: return
            val key = posted.key
            if (key.isNullOrEmpty()) return
            // A managed (work) profile app carries the SAME package name as the
            // personal one, and the service's block arms are anchored to the
            // current user — so a lock set here must not silence the other
            // profile's copy of the app. Mirror-contract discipline.
            if (posted.user != Process.myUserHandle()) return
            // Nothing is blocked while the engine is dead, so nothing is to be
            // silenced: a correct early exit, not a degraded one.
            val service = DetoxoAccessibilityService.instance ?: return
            if (!service.shouldSuppressNotification(pkg)) return
            // EVO-038: a block silences the feed, never the person. Read last —
            // only notifications already destined for cancellation reach it.
            if (SuppressionDecision.isAlwaysAllowed(posted.notification?.category)) return
            cancelNotification(key)
        } catch (t: Throwable) {
            // Swallowed, never rethrown: a listener that crashes is unbound by
            // the system and silently stops working for the rest of the
            // session. Only the exception's TYPE is logged — the surrounding
            // idiom is "${t.message}", but a message on this path could embed a
            // package name or notification key, and the guarantee above says
            // none reaches Logcat.
            Log.w(TAG, "suppress failed: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        private const val TAG = "DetoxoNotifListener"

        @Volatile
        var instance: DetoxoNotificationListener? = null
            private set

        /**
         * Binds the listener only while suppression is on. Off means Detoxo
         * receives no notifications at all, rather than receiving every one on
         * the device and discarding it.
         *
         * This is the *responsive* half only — it cannot cover a reboot, a
         * package replace, or a grant that never crossed the toggle. The
         * durable half is the check in [onListenerConnected]; both are needed.
         *
         * Both calls are best-effort: they throw when the grant is absent
         * (the common case, since the toggle can precede the grant).
         */
        fun syncBinding(context: Context, enabled: Boolean) {
            runCatching {
                if (enabled) {
                    requestRebind(
                        ComponentName(context, DetoxoNotificationListener::class.java),
                    )
                } else {
                    instance?.requestUnbind()
                }
            }
        }
    }
}
