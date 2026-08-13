package com.errorxperts.detoxo.channels

import android.app.Activity
import android.app.AppOpsManager
import android.app.admin.DevicePolicyManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.view.WindowManager
import com.errorxperts.detoxo.MainActivity
import com.errorxperts.detoxo.accessibility.DetoxoAccessibilityService
import com.errorxperts.detoxo.admin.DetoxoDeviceAdminReceiver
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ContentCounterStore
import com.errorxperts.detoxo.widget.ContentCounterWidgetProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Handles Dart -> native commands: config/settings push, permission queries and
 * launches, and direct block actions used for testing and PIN/overlay screens.
 */
class CommandHandler(
    private val context: Context,
    private var activity: Activity?,
) : MethodChannel.MethodCallHandler {

    private val store = ConfigStore(context)

    // Off-main-thread executor for the (potentially slow) installed-apps query;
    // results are posted back on the platform thread, which Flutter requires.
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attachActivity(activity: Activity?) {
        this.activity = activity
    }

    private companion object {
        /** Conscious plan token (shares the legacy "CURIOUS" wire). */
        const val PLAN_CONSCIOUS = "CURIOUS"

        /** One Reel / Unblock plan token (allow N reels, then re-block). */
        const val PLAN_ONE_REEL = "ONE_REEL"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pushConfig" -> {
                store.platformsConfigJson = call.argument<String>("json")
                DetoxoAccessibilityService.instance?.reload()
                result.success(true)
            }
            "pushSettings" -> {
                // The plan is stored verbatim. The Conscious bank is NOT reset on
                // a plan transition here — it resets only on the explicit
                // resetConsciousBank command (a genuine user entry), so an
                // auto-revert *into* Conscious keeps the earned bank.
                call.argument<String>("activePlan")?.let { plan ->
                    store.activePlan = plan
                }
                call.argument<String>("defaultBlockMode")?.let { store.defaultBlockMode = it }
                call.argument<List<String>>("enabledPlatforms")?.let {
                    store.enabledPlatforms = it.toSet()
                }
                call.argument<Boolean>("vibration")?.let { store.vibrationEnabled = it }
                call.argument<Boolean>("masterEnabled")?.let { store.masterEnabled = it }
                call.argument<Number>("pauseUntil")?.let { store.pauseUntil = it.toLong() }
                // The target allowance persists here (survives restart); the
                // consumed-count is NOT reset here — only the imperative
                // armReelSession re-arms, so an unrelated push can't refill it.
                call.argument<Number>("reelAllowance")?.let {
                    store.reelAllowance = it.toInt()
                }
                call.argument<Number>("consciousEarnDivisor")?.let {
                    store.consciousEarnDivisor = it.toInt()
                }
                call.argument<Number>("consciousMaxBankMs")?.let {
                    store.consciousMaxBankMs = it.toLong()
                }
                call.argument<Boolean>("blockAdultWebsites")?.let {
                    store.blockAdultWebsites = it
                }
                call.argument<Boolean>("blockWebsitesForBlockedApps")?.let {
                    store.blockWebsitesForBlockedApps = it
                }
                DetoxoAccessibilityService.instance?.reload()
                result.success(true)
            }
            "pushWebBlocklist" -> {
                store.webBlocklistJson = call.argument<String>("json")
                DetoxoAccessibilityService.instance?.reload()
                result.success(true)
            }
            "pushProtectedApps" -> {
                // Enabled package names only — names/categories never cross the
                // channel, and protected packages are never logged.
                store.protectedPackages =
                    call.argument<List<String>>("packages")?.toSet() ?: emptySet()
                DetoxoAccessibilityService.instance?.reload()
                result.success(true)
            }
            "consciousState" -> result.success(
                DetoxoAccessibilityService.instance?.consciousSnapshot() ?: mapOf(
                    "bankMs" to store.consciousBankMs,
                    "maxBankMs" to store.consciousMaxBankMs,
                    "watching" to false,
                    "blocked" to (store.activePlan == PLAN_CONSCIOUS && store.consciousBankMs <= 0L),
                    "active" to (store.activePlan == PLAN_CONSCIOUS),
                ),
            )
            "resetConsciousBank" -> {
                // Explicit fresh-start reset, fired only on a genuine user entry
                // to Conscious (auto-reverts keep the earned bank).
                store.resetConsciousBank(System.currentTimeMillis())
                DetoxoAccessibilityService.instance?.reload()
                result.success(true)
            }
            "armReelSession" -> {
                // (Re)arm One Reel / Unblock with a fresh allowance. Imperative
                // so an unrelated pushSettings never re-arms mid-session.
                val count = (call.argument<Number>("count")?.toInt() ?: 1).coerceIn(1, 20)
                store.reelAllowance = count
                store.activePlan = PLAN_ONE_REEL
                store.resetReelSession()
                DetoxoAccessibilityService.instance?.armReelSession()
                result.success(true)
            }
            "reelSessionState" -> result.success(
                DetoxoAccessibilityService.instance?.reelSessionSnapshot() ?: mapOf(
                    "consumed" to store.reelsConsumed,
                    "allowance" to store.reelAllowance,
                    "blocked" to (store.activePlan == PLAN_ONE_REEL &&
                        store.reelsConsumed >= store.reelAllowance),
                    "active" to (store.activePlan == PLAN_ONE_REEL),
                ),
            )
            "isAccessibilityEnabled" -> result.success(isAccessibilityEnabled())
            "openAccessibilitySettings" ->
                result.success(launch(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)))
            "canDrawOverlays" -> result.success(Settings.canDrawOverlays(context))
            "requestOverlayPermission" -> result.success(
                launch(
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${context.packageName}"),
                    ),
                ),
            )
            "hasUsageAccess" -> result.success(hasUsageAccess())
            "openUsageAccessSettings" ->
                result.success(launch(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)))
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBattery())
            "requestIgnoreBatteryOptimizations" -> result.success(
                launch(
                    Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${context.packageName}"),
                    ),
                ),
            )
            "isDeviceAdminActive" -> result.success(isDeviceAdminActive())
            "requestDeviceAdmin" -> result.success(requestDeviceAdmin())
            "removeDeviceAdmin" -> {
                removeDeviceAdmin()
                result.success(true)
            }
            "performBack" -> {
                DetoxoAccessibilityService.instance?.performBackPublic()
                result.success(true)
            }
            "killApp" -> {
                val pkg = call.argument<String>("package")
                if (pkg != null) DetoxoAccessibilityService.instance?.killApp(pkg)
                result.success(true)
            }
            "lockScreen" -> {
                DetoxoAccessibilityService.instance?.lockScreen()
                result.success(true)
            }
            "setSecureScreen" -> {
                // PIN lock privacy: FLAG_SECURE hides the window in Recents and
                // blocks screenshots. Runs on the platform (UI) thread.
                val on = call.argument<Boolean>("enabled") ?: false
                activity?.window?.let { w ->
                    if (on) w.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else w.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(true)
            }
            "lastScreenOff" -> result.success(MainActivity.lastScreenOffMillis)
            "blockStats" -> {
                val (today, total, date) = store.blockStats()
                result.success(mapOf("today" to today, "total" to total, "date" to date))
            }
            "contentCounterSnapshot" -> {
                // Prefer the live service (fresh in-memory bubble/widget state),
                // else read the store directly so it works when the service is dead.
                val snap = DetoxoAccessibilityService.instance?.contentCounter?.snapshot()
                    ?: ContentCounterStore(context).snapshot(dateKey())
                result.success(snap)
            }
            "setContentCounterEnabled" -> {
                val on = call.argument<Boolean>("enabled") ?: true
                ContentCounterStore(context).enabled = on
                DetoxoAccessibilityService.instance?.contentCounter?.setEnabled(on)
                result.success(true)
            }
            "setContentBubbleEnabled" -> {
                val on = call.argument<Boolean>("enabled") ?: true
                ContentCounterStore(context).bubbleEnabled = on
                DetoxoAccessibilityService.instance?.contentCounter?.setBubbleEnabled(on)
                result.success(true)
            }
            "refreshContentWidget" -> {
                ContentCounterWidgetProvider.pushUpdate(
                    context,
                    ContentCounterStore(context).snapshot(dateKey()),
                )
                result.success(true)
            }
            "setCounterStyle" -> {
                // Persist the changed surface(s), then live-re-render: the visible
                // bubble via the service, and every pinned widget directly.
                val store = ContentCounterStore(context)
                call.argument<Map<String, Any?>>("bubble")?.let {
                    store.bubbleStyleJson = JSONObject(it).toString()
                }
                call.argument<Map<String, Any?>>("widget")?.let {
                    store.widgetStyleJson = JSONObject(it).toString()
                }
                DetoxoAccessibilityService.instance?.contentCounter?.onStyleChanged()
                ContentCounterWidgetProvider.pushUpdate(context, store.snapshot(dateKey()))
                result.success(true)
            }
            "pinContentWidget" -> result.success(pinContentWidget())
            "deviceInfo" -> result.success(deviceInfo())
            "installedPackages" -> {
                // Enumerating launchable apps can take 100s of ms on busy
                // devices — run it off the platform thread, post back on it.
                ioExecutor.execute {
                    val packages = queryLaunchablePackages()
                    mainHandler.post { result.success(packages) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * User-facing, launchable apps: every package exposing a MAIN/LAUNCHER
     * activity, de-duplicated (an app may register several launcher aliases).
     * Satisfied by the manifest `<queries>` MAIN entry, so it does not strictly
     * need QUERY_ALL_PACKAGES. Returns an empty list on failure so the Dart side
     * still treats install state as "unknown" rather than dropping the blocklist.
     */
    private fun queryLaunchablePackages(): List<String>? {
        return try {
            val pm = context.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val resolved: List<ResolveInfo> =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
                } else {
                    @Suppress("DEPRECATION")
                    pm.queryIntentActivities(intent, 0)
                }
            val seen = LinkedHashSet<String>(resolved.size)
            for (info in resolved) {
                info.activityInfo?.packageName?.let { seen.add(it) }
            }
            seen.toList()
        } catch (_: Throwable) {
            // null (not empty) => Dart treats install state as unknown and shows
            // the full blocklist rather than hiding every app.
            null
        }
    }

    /** Requests the launcher pin the reel counter widget. Returns false if unsupported. */
    private fun pinContentWidget(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val mgr = context.getSystemService(AppWidgetManager::class.java) ?: return false
            if (!mgr.isRequestPinAppWidgetSupported) return false
            val provider = ComponentName(context, ContentCounterWidgetProvider::class.java)
            mgr.requestPinAppWidget(provider, null, null)
        } catch (_: Throwable) {
            false
        }
    }

    private fun dateKey(): String =
        SimpleDateFormat("dd-MM-yyyy", Locale.US).format(System.currentTimeMillis())

    private fun isAccessibilityEnabled(): Boolean {
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

    private fun hasUsageAccess(): Boolean {
        return try {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Throwable) {
            false
        }
    }

    private fun isIgnoringBattery(): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun isDeviceAdminActive(): Boolean {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        return dpm.isAdminActive(ComponentName(context, DetoxoDeviceAdminReceiver::class.java))
    }

    private fun requestDeviceAdmin(): Boolean {
        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
            putExtra(
                DevicePolicyManager.EXTRA_DEVICE_ADMIN,
                ComponentName(context, DetoxoDeviceAdminReceiver::class.java),
            )
            putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Enable to protect Detoxo from being uninstalled while active.",
            )
        }
        return launch(intent)
    }

    private fun removeDeviceAdmin() {
        try {
            val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            dpm.removeActiveAdmin(ComponentName(context, DetoxoDeviceAdminReceiver::class.java))
        } catch (_: Throwable) {
        }
    }

    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "brand" to Build.BRAND,
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "sdkInt" to Build.VERSION.SDK_INT,
    )

    private fun launch(intent: Intent): Boolean {
        return try {
            val host = activity
            if (host != null) {
                host.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            true
        } catch (_: Throwable) {
            false
        }
    }
}
