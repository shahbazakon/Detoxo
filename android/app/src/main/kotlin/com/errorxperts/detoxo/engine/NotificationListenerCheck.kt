package com.errorxperts.detoxo.engine

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import com.errorxperts.detoxo.notifications.DetoxoNotificationListener

/**
 * Whether Detoxo's notification listener is enabled in Settings.Secure.
 * The exact shape of [AccessibilityCheck] against a different setting — see it
 * for why both flattened forms are accepted.
 */
object NotificationListenerCheck {

    // Settings.Secure.ENABLED_NOTIFICATION_LISTENERS is @hide, so the raw key.
    private const val ENABLED_LISTENERS = "enabled_notification_listeners"

    fun isEnabled(context: Context): Boolean {
        val component = ComponentName(context, DetoxoNotificationListener::class.java)
        // Most ROMs write the long form (pkg/pkg.Class), but some OEMs write the
        // short form (pkg/.Class). Accept either — a false "not enabled" would
        // send an already-granted user down the restricted-settings recovery flow.
        val long = component.flattenToString()
        val short = component.flattenToShortString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            ENABLED_LISTENERS,
        ) ?: return false
        return enabled.split(':').any {
            it.equals(long, ignoreCase = true) || it.equals(short, ignoreCase = true)
        }
    }
}
