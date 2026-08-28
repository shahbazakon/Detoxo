package com.errorxperts.detoxo.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Boot / package-replaced hook. An AccessibilityService is re-bound by the OS
 * automatically once enabled, so no manual restart happens here — but some
 * OEMs fail to rebind after a force-stop, so this (re)arms the watchdog job
 * that detects a dead service and notifies the user. The first periodic run
 * judges liveness; checking inline here would race the post-boot rebind.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        Log.i("DetoxoBoot", "received ${intent?.action}")
        WatchdogJobService.schedule(context)
    }
}
