package com.errorxperts.detoxo.overlay

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.WindowManager

/** Shared by the counter bubble and the block screen: the overlay window type
 *  with its pre-O fallback, and the one way Detoxo launches itself from a
 *  window that has no Activity. Pure functions — safe to reference from JVM
 *  unit tests as long as nothing here runs in an object initializer. */

internal fun overlayType(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
        @Suppress("DEPRECATION")
        WindowManager.LayoutParams.TYPE_PHONE
    }

/** Foregrounds Detoxo's own task (singleTop MainActivity). Never throws. */
internal fun launchDetoxo(context: Context) {
    try {
        val intent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            } ?: return
        context.startActivity(intent)
    } catch (t: Throwable) {
        Log.w("Overlay", "launchDetoxo failed: ${t.message}")
    }
}
