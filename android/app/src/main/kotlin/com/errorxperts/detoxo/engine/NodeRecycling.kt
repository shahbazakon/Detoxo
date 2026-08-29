package com.errorxperts.detoxo.engine

import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Recycles an obtained node below API 33 (where recycle() became a no-op).
 * The tree walks run per accessibility event — unrecycled nodes are a steady
 * native-heap leak on the hottest path in the app. Swallows the
 * already-recycled IllegalStateException so a double-recycle on a rare path
 * can never crash the service.
 */
fun AccessibilityNodeInfo?.recycleSafe() {
    if (this == null || Build.VERSION.SDK_INT >= 33) return
    try {
        @Suppress("DEPRECATION")
        recycle()
    } catch (_: Throwable) {
    }
}
