package com.errorxperts.detoxo.engine

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import com.errorxperts.detoxo.accessibility.DetoxoAccessibilityService

/**
 * Whether Detoxo's accessibility service is enabled in Settings.Secure.
 * Shared by the command channel and the watchdog. Note this is the SETTING,
 * not liveness — an OEM force-stop can kill the service while the setting
 * still lists it (see `serviceAlive`).
 */
object AccessibilityCheck {

    fun isEnabled(context: Context): Boolean {
        val component = ComponentName(context, DetoxoAccessibilityService::class.java)
        // Most ROMs write the long form (pkg/pkg.Class), but some OEMs write the
        // short form (pkg/.Class). Accept either — a false "not enabled" would
        // send an already-granted user down the restricted-settings recovery flow.
        val long = component.flattenToString()
        val short = component.flattenToShortString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return enabled.split(':').any {
            it.equals(long, ignoreCase = true) || it.equals(short, ignoreCase = true)
        }
    }
}
