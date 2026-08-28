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
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
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
import com.errorxperts.detoxo.engine.AccessibilityCheck
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ContentCounterStore
import com.errorxperts.detoxo.engine.DateKeys
import com.errorxperts.detoxo.widget.ContentCounterWidgetProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
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
                // Fail-safe like pushWebBlocklist: an absent or malformed arg is
                // a no-op, never a wipe — a nulled config parses to EMPTY, which
                // kills both blocking and counting until the next good push.
                call.argument<String>("json")?.let { json ->
                    if (runCatching { JSONObject(json) }.isSuccess) {
                        store.platformsConfigJson = json
                        DetoxoAccessibilityService.instance?.reload()
                    }
                }
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
                // Fail-safe like pushProtectedApps: an absent or malformed arg
                // is a no-op, never a wipe. Clearing requires an explicit "[]".
                // An unchanged payload (every screen entry re-pushes) skips the
                // prefs rewrite; a changed one swaps the rule set only — a full
                // reload() re-parsed the 31 KB platforms config per site toggle.
                call.argument<String>("json")?.let { json ->
                    if (json != store.webBlocklistJson &&
                        runCatching { JSONArray(json) }.isSuccess
                    ) {
                        store.webBlocklistJson = json
                        DetoxoAccessibilityService.instance?.refreshWebBlocklist()
                    }
                }
                result.success(true)
            }
            "pushProtectedApps" -> {
                // Package names only — names/categories never cross the channel,
                // and protected packages are never logged. Fail-safe: an absent
                // or malformed arg is a no-op, never a wipe (clearing protection
                // requires an explicit empty list). An unchanged set skips the
                // prefs rewrite and the service refresh entirely.
                call.argument<List<*>>("packages")?.let { list ->
                    val next = list.filterIsInstance<String>().toSet()
                    if (next != store.protectedPackages) {
                        store.protectedPackages = next
                        DetoxoAccessibilityService.instance?.refreshProtectedPackages()
                    }
                }
                result.success(true)
            }
            "pushAppBlocklist" -> {
                // Custom whole-app blocks. Same fail-safe contract as
                // pushProtectedApps: absent/malformed arg = no-op (clearing
                // requires an explicit empty list); an unchanged set skips the
                // prefs rewrite and the service refresh.
                call.argument<List<*>>("packages")?.let { list ->
                    val next = list.filterIsInstance<String>().toSet()
                    if (next != store.blockedAppPackages) {
                        store.blockedAppPackages = next
                        DetoxoAccessibilityService.instance?.refreshAppBlocklist()
                    }
                }
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
                // to Conscious (auto-reverts keep the earned bank). The service
                // hook (not a plain reload) also drops its cached/unflushed bank
                // so the pending accrual can't resurrect the zeroed value.
                store.resetConsciousBank()
                DetoxoAccessibilityService.instance?.onConsciousBankReset()
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
            // EVO-013: the setting can say enabled while the service is dead
            // (OEM force-stop). The instance is the truth for "running".
            "serviceAlive" ->
                result.success(DetoxoAccessibilityService.instance != null)
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
            // Monotonic clocks: the PIN lockout anchor a Settings clock change
            // cannot move; BOOT_COUNT makes a cross-boot reading detectable
            // (elapsedRealtime alone restarts at 0 and is ambiguous).
            "monotonicNow" -> result.success(
                mapOf(
                    "elapsedMs" to android.os.SystemClock.elapsedRealtime(),
                    "bootCount" to try {
                        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
                    } catch (_: Throwable) {
                        -1
                    },
                ),
            )
            "blockStats" -> {
                val (today, total, date) = store.blockStats(DateKeys.today())
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
            "installedApps" -> {
                // Label + icon loads are slower still (per-app resource reads);
                // same off-thread pattern. Dart caches the result.
                ioExecutor.execute {
                    val apps = queryInstalledApps()
                    mainHandler.post { result.success(apps) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * MAIN/LAUNCHER activities. Satisfied by the manifest `<queries>` MAIN
     * entry, so it does not strictly need QUERY_ALL_PACKAGES. Throws on
     * failure — callers map that to null ("install state unknown").
     */
    private fun resolveLaunchables(): List<ResolveInfo> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }
    }

    /**
     * User-facing, launchable apps: every package exposing a MAIN/LAUNCHER
     * activity, de-duplicated (an app may register several launcher aliases).
     */
    private fun queryLaunchablePackages(): List<String>? {
        return try {
            val resolved = resolveLaunchables()
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

    /**
     * Launchable apps with display metadata for the add-app picker:
     * `{package, label, icon}` per app, icon a 96px PNG (or null). Detoxo
     * itself is excluded — blocking or protecting it is meaningless. Null on
     * total failure, mirroring [queryLaunchablePackages].
     */
    private fun queryInstalledApps(): List<Map<String, Any?>>? {
        return try {
            val pm = context.packageManager
            val seen = HashSet<String>()
            val out = ArrayList<Map<String, Any?>>()
            for (info in resolveLaunchables()) {
                val pkg = info.activityInfo?.packageName ?: continue
                if (pkg == context.packageName || !seen.add(pkg)) continue
                val label = try {
                    info.loadLabel(pm).toString()
                } catch (_: Throwable) {
                    pkg
                }
                // Per-app: one corrupt icon must not kill the whole list.
                val icon = try {
                    rasterizeIcon(info.loadIcon(pm))
                } catch (_: Throwable) {
                    null
                }
                out.add(mapOf("package" to pkg, "label" to label, "icon" to icon))
            }
            out
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Draws any Drawable (adaptive / vector / bitmap) into a 96px PNG. Drawing
     * at target bounds is the downscale — no intermediate full-size bitmap.
     */
    private fun rasterizeIcon(drawable: Drawable?): ByteArray? {
        if (drawable == null) return null
        val edge = 96
        val bmp = Bitmap.createBitmap(edge, edge, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, edge, edge)
        drawable.draw(Canvas(bmp))
        val bytes = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, bytes)
        bmp.recycle()
        return bytes.toByteArray()
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

    private fun dateKey(): String = DateKeys.today()

    private fun isAccessibilityEnabled(): Boolean = AccessibilityCheck.isEnabled(context)

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
