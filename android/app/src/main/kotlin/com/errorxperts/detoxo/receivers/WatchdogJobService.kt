package com.errorxperts.detoxo.receivers

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.errorxperts.detoxo.R
import com.errorxperts.detoxo.accessibility.DetoxoAccessibilityService
import com.errorxperts.detoxo.engine.AccessibilityCheck
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ContentCounterStore
import com.errorxperts.detoxo.engine.DateKeys
import com.errorxperts.detoxo.engine.ServiceEventBus
import com.errorxperts.detoxo.engine.UsageQuery
import com.errorxperts.detoxo.widget.ContentCounterWidgetProvider

/**
 * Periodic "is protection actually alive?" check. An accessibility service
 * cannot be rebound programmatically — after an OEM force-stop only the user
 * can re-enable it — so the best possible recovery is detect + notify: a
 * "Protection stopped" notification deep-linking to the Accessibility settings.
 *
 * Scheduled (idempotently, persisted across reboots) from the service's own
 * onServiceConnected and from [BootReceiver].
 */
class WatchdogJobService : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        checkAndNotify(this)
        // A pushed rule window may have opened or closed since the last
        // window-state event — post `ruleBoundary` so a live Dart re-resolves
        // and re-pushes (dropped when nobody listens; the next resume re-pushes
        // anyway). Rides this tick: no new job, no alarm.
        try {
            checkRuleBoundary(this)
        } catch (t: Throwable) {
            Log.w(TAG, "rule boundary check failed: ${t.message}")
        }
        // EVO-029: re-measure the rule limits that have not run out yet. Dart
        // can only do this while it is running, so without this a daily budget
        // does not start enforcing until Detoxo is next opened. Gated on the
        // snapshot actually having a pending budget, so it costs nothing for
        // everyone else.
        try {
            reconcileLimits(this)
        } catch (t: Throwable) {
            Log.w(TAG, "limit reconcile failed: ${t.message}")
        }
        // The home widget only re-renders on a count, so after midnight it kept
        // showing yesterday's total as "today" until the first reel. Piggyback
        // on this periodic job (no wakeups of its own, unlike updatePeriodMillis);
        // pushUpdate is a cheap no-op when nothing is pinned.
        // ponytail: up to 15 min of stale "today" after midnight.
        try {
            ContentCounterWidgetProvider.pushUpdate(
                this,
                ContentCounterStore(this).snapshot(DateKeys.today()),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "widget refresh failed: ${t.message}")
        }
        return false // all work is synchronous
    }

    override fun onStopJob(params: JobParameters?): Boolean = false

    companion object {
        private const val TAG = "DetoxoWatchdog"
        private const val JOB_ID = 1126
        private const val NOTIF_ID = 1127
        private const val CHANNEL_ID = "detoxo_watchdog_channel"
        private const val PERIOD_MS = 15 * 60 * 1000L

        /** At most one nag per window — the outage persists, the user read it. */
        private const val RENOTIFY_MS = 6 * 60 * 60 * 1000L

        /** Idempotent: a still-pending job is left alone. */
        fun schedule(context: Context) {
            try {
                val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
                if (scheduler.getPendingJob(JOB_ID) != null) return
                scheduler.schedule(
                    JobInfo.Builder(
                        JOB_ID,
                        ComponentName(context, WatchdogJobService::class.java),
                    )
                        .setPeriodic(PERIOD_MS)
                        .setPersisted(true) // survives reboot (RECEIVE_BOOT_COMPLETED held)
                        .build(),
                )
            } catch (t: Throwable) {
                Log.w(TAG, "schedule failed: ${t.message}")
            }
        }

        /**
         * Through the live service when there is one (it holds the in-memory
         * boundary mirror), else straight from prefs.
         */
        fun checkRuleBoundary(context: Context) {
            val now = System.currentTimeMillis()
            val service = DetoxoAccessibilityService.instance
            if (service != null) {
                service.checkRuleBoundary(now)
                return
            }
            val store = ConfigStore(context)
            val boundary = store.nextBoundaryMs
            if (boundary > 0L && now >= boundary) {
                store.nextBoundaryMs = 0L
                ServiceEventBus.post("ruleBoundary", mapOf("atMs" to boundary))
            }
        }

        /**
         * Measure every pending rule limit against today's UsageStats and flip
         * the ones that are used up. A flip posts `ruleBoundary`, so a live
         * Dart re-resolves and agrees; with no Dart the engine simply starts
         * blocking, and Dart's next push re-derives the same verdict.
         *
         * Needs the live service: the snapshot it flips is in-memory, and there
         * is nothing to enforce it when the service is dead anyway.
         */
        fun reconcileLimits(context: Context) {
            val service = DetoxoAccessibilityService.instance ?: return
            if (!service.hasPendingRuleLimits()) return
            if (!UsageQuery.hasAccess(context)) return
            val now = System.currentTimeMillis()
            val start = UsageQuery.startOfDay(now)
            if (start >= now) return

            // Only the budgets that exist pay for their query — each is a
            // binder round trip over the whole day, every tick, all day, with
            // Detoxo closed: a time limit never needs the event log, an open
            // limit never needs the per-app totals.
            val usageMs = HashMap<String, Long>()
            if (service.hasPendingUsageLimits()) {
                for (row in UsageQuery.appUsage(context, start, now)) {
                    val pkg = row["package"] as? String ?: continue
                    usageMs[pkg] = (row["foregroundMillis"] as? Number)?.toLong() ?: 0L
                }
            }
            // The same transition rule Dart's `countOpens` and the wall's
            // `opensToday` apply: an app resuming its own next activity is not
            // a new open. Counting every MOVE_TO_FOREGROUND flipped an open
            // limit early whenever the phone was away from Dart.
            val opens = if (service.hasPendingOpenLimits()) {
                UsageQuery.countOpensByPackage(
                    UsageQuery.events(context, start, now).asSequence().mapNotNull { row ->
                        val pkg = row["package"] as? String ?: return@mapNotNull null
                        val type = (row["type"] as? Number)?.toInt() ?: return@mapNotNull null
                        pkg to type
                    },
                )
            } else {
                emptyMap()
            }
            if (service.markRuleLimitsSpent(usageMs, opens)) {
                ServiceEventBus.post("ruleBoundary", mapOf("atMs" to now))
            }
        }

        fun checkAndNotify(context: Context) {
            val store = ConfigStore(context)
            // The user turned protection off themselves — nothing to report.
            if (!store.masterEnabled) return
            // JobService runs in the app's (single) process, so a live service
            // instance is directly visible. Recovered → clear the alert AND the
            // debounce, so a stale "Protection stopped" never outlives the
            // outage and a NEW outage within 6h is not silently swallowed.
            if (DetoxoAccessibilityService.instance != null) {
                clearAlert(context, store)
                return
            }
            // Only nag someone who actually had protection: the setting still
            // lists the service (dead after a force-stop) or it connected at
            // least once before (the setting itself was cleared by the OS/OEM).
            if (!AccessibilityCheck.isEnabled(context) && !store.serviceEverConnected) return
            val now = System.currentTimeMillis()
            if (now - store.lastWatchdogNotifiedMs < RENOTIFY_MS) return
            // Arm the debounce only when the notification can actually reach
            // the shade: with POST_NOTIFICATIONS denied (13+) nm.notify()
            // drops silently without throwing, and a pre-armed debounce would
            // delay the first REAL alert by up to 6h after the user grants it.
            if (notifyProtectionStopped(context)) {
                store.lastWatchdogNotifiedMs = now
            }
        }

        /** Recovery: drop the shade alert and re-arm the notify debounce. */
        fun clearAlert(context: Context, store: ConfigStore = ConfigStore(context)) {
            if (store.lastWatchdogNotifiedMs == 0L) return
            store.lastWatchdogNotifiedMs = 0L
            try {
                context.getSystemService(NotificationManager::class.java)?.cancel(NOTIF_ID)
            } catch (_: Throwable) {
            }
        }

        /** Returns true only when the notification was actually handed to the shade. */
        private fun notifyProtectionStopped(context: Context): Boolean {
            try {
                val nm = context.getSystemService(NotificationManager::class.java)
                    ?: return false
                if (!nm.areNotificationsEnabled()) return false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            context.getString(R.string.watchdog_channel_name),
                            NotificationManager.IMPORTANCE_DEFAULT,
                        ).apply {
                            description =
                                context.getString(R.string.watchdog_channel_description)
                        },
                    )
                    // A user-blocked channel drops the notification as
                    // silently as a missing permission.
                    val ch = nm.getNotificationChannel(CHANNEL_ID)
                    if (ch != null && ch.importance == NotificationManager.IMPORTANCE_NONE) {
                        return false
                    }
                }
                val tap = PendingIntent.getActivity(
                    context,
                    0,
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                nm.notify(
                    NOTIF_ID,
                    NotificationCompat.Builder(context, CHANNEL_ID)
                        .setContentTitle(context.getString(R.string.watchdog_title))
                        .setContentText(context.getString(R.string.watchdog_text))
                        .setSmallIcon(R.mipmap.ic_launcher)
                        .setContentIntent(tap)
                        .setAutoCancel(true)
                        .build(),
                )
                Log.i(TAG, "protection-stopped notification posted")
                return true
            } catch (t: Throwable) {
                // Missing POST_NOTIFICATIONS etc. — the watchdog must never crash.
                Log.w(TAG, "notify failed: ${t.message}")
                return false
            }
        }
    }
}
