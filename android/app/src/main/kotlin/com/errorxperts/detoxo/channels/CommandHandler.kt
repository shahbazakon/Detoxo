package com.errorxperts.detoxo.channels

import android.app.Activity
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
import android.provider.Settings
import android.view.WindowManager
import com.errorxperts.detoxo.MainActivity
import com.errorxperts.detoxo.accessibility.DetoxoAccessibilityService
import com.errorxperts.detoxo.admin.DetoxoDeviceAdminReceiver
import com.errorxperts.detoxo.engine.AccessibilityCheck
import com.errorxperts.detoxo.engine.BrowserUrlExtractor
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ContentCounterStore
import com.errorxperts.detoxo.engine.DateKeys
import com.errorxperts.detoxo.engine.NotificationListenerCheck
import com.errorxperts.detoxo.engine.UsageQuery
import com.errorxperts.detoxo.notifications.DetoxoNotificationListener
import com.errorxperts.detoxo.overlay.BlockScreenOverlay
import com.errorxperts.detoxo.overlay.BlockScreenPayload
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
                // Notification suppression drives the LISTENER BINDING, not just
                // a flag: while it is off Detoxo unbinds, so it receives no
                // notifications at all rather than receiving every one on the
                // device and discarding it. Only on a real change — requestRebind
                // on every settings push would churn the binding.
                call.argument<Boolean>("suppressNotifications")?.let {
                    if (it != store.suppressNotifications) {
                        store.suppressNotifications = it
                        DetoxoNotificationListener.syncBinding(context, it)
                    }
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
            "pushNudgeConfig" -> {
                // The advisory dwell nudge: its switch, its tuning and the apps
                // it watches. Same fail-safe contract as pushProtectedApps —
                // each absent/malformed arg is an independent no-op, never a
                // wipe. One refresh at the end whatever changed: unlike a
                // blocklist this touches no hot-path set, so there is nothing
                // to save by diffing each field.
                call.argument<Boolean>("enabled")?.let { store.nudgeEnabled = it }
                call.argument<List<*>>("packages")?.let { list ->
                    store.nudgePackages = list.filterIsInstance<String>().toSet()
                }
                call.argument<Number>("thresholdStepMs")?.let {
                    store.nudgeStepMs = it.toLong()
                }
                call.argument<Number>("dailyCap")?.let { store.nudgeDailyCap = it.toInt() }
                DetoxoAccessibilityService.instance?.refreshNudgeConfig()
                result.success(true)
            }
            "pushRules" -> {
                // The resolved rules snapshot (schedules as absolute windows,
                // spent limits, the daily reel limit's meter). Same fail-safe
                // contract as pushWebBlocklist: an absent or malformed json is a
                // no-op, never a wipe (clearing requires an explicit "[]"); an
                // unchanged json skips the prefs rewrite. The boundary is always
                // written — it moves even when the snapshot does not — and the
                // engine re-parses only when the snapshot string actually
                // changed (RuleEngine.setSnapshot holds the last source).
                // Clamped like armReelSession below: a negative boundary would
                // read as "none" and silently stop the ruleBoundary event for
                // the life of the snapshot.
                call.argument<Number>("nextBoundaryMs")?.let {
                    store.nextBoundaryMs = it.toLong().coerceAtLeast(0L)
                }
                call.argument<String>("json")?.let { json ->
                    if (json != store.rulesJson && runCatching { JSONArray(json) }.isSuccess) {
                        store.rulesJson = json
                    }
                }
                DetoxoAccessibilityService.instance?.refreshRules()
                result.success(true)
            }
            "pushTemporaryUnblocks" -> {
                // M8's per-target grants ("Instagram for 15 minutes"). The
                // pushWebBlocklist arm verbatim: an absent or malformed json is
                // a no-op, never a wipe (clearing requires an explicit "[]"), an
                // unchanged payload skips the prefs rewrite, and only the narrow
                // registry is refreshed — never a full reload().
                call.argument<String>("json")?.let { json ->
                    if (json != store.temporaryUnblocksJson &&
                        runCatching { JSONArray(json) }.isSuccess
                    ) {
                        store.temporaryUnblocksJson = json
                        DetoxoAccessibilityService.instance?.refreshTemporaryUnblocks()
                    }
                }
                result.success(true)
            }
            "takePendingUnblock" -> {
                // Read-and-CLEAR, exactly once: the wall armed "TYPE|id" when the
                // user tapped "Unblock for a while", and Dart opens the duration
                // sheet for it on the launch that tap triggered. Replaying a
                // sticky event instead would re-offer a bypass for a target from
                // a previous session on the next engine attach — and so would a
                // key with no expiry, which is why the store stamps it and drops
                // anything older than its TTL.
                result.success(store.takePendingUnblock(System.currentTimeMillis()))
            }
            "takeNativeGrants" -> {
                // EVO-050: grants the user took ON the wall, already enforced
                // natively. Read-and-clear, so Dart absorbs each exactly once
                // and its next push — which rewrites the whole enforced list —
                // carries them instead of deleting them.
                result.success(store.takeNativeGrants())
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
            "isNotificationListenerEnabled" ->
                result.success(NotificationListenerCheck.isEnabled(context))
            "openNotificationListenerSettings" ->
                result.success(launch(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)))
            "queryAppUsage", "queryUsageEvents" -> {
                // The two arms that THROW: an empty list is indistinguishable
                // from a genuinely quiet day, so a missing grant or bad bounds
                // must reach Dart as an error, never as a confident zero
                // (EVO-014). Everything else in this handler stays fail-safe.
                val start = call.argument<Number>("startMillis")?.toLong()
                val end = call.argument<Number>("endMillis")?.toLong()
                if (start == null || end == null || !UsageQuery.validBounds(start, end)) {
                    result.error("BAD_ARGS", "startMillis/endMillis missing or invalid", null)
                    return
                }
                if (!hasUsageAccess()) {
                    result.error("USAGE_ACCESS_DENIED", "Usage access is not granted", null)
                    return
                }
                val wantEvents = call.method == "queryUsageEvents"
                // A day of events is a few hundred rows; a week a few thousand.
                // Same off-thread / post-back pattern as installedApps below.
                ioExecutor.execute {
                    val out = runCatching {
                        if (wantEvents) UsageQuery.events(context, start, end)
                        else UsageQuery.appUsage(context, start, end)
                    }
                    mainHandler.post {
                        out.fold(
                            { result.success(it) },
                            { result.error("USAGE_QUERY_FAILED", it.message, null) },
                        )
                    }
                }
            }
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
            // ── Block screen (intervention wall) ──────────────────────────
            // The overlay is an object that needs only a Context, so a style
            // preview from Dart works with the service down — unlike the three
            // service-routed arms above.
            "showBlockScreen" -> {
                val payload = BlockScreenPayload.fromMap(call.arguments as? Map<*, *>)?.sanitised()
                result.success(
                    payload != null &&
                        BlockScreenOverlay.show(context, payload, setOf(context.packageName), preview = true),
                )
            }
            "hideBlockScreen" -> {
                BlockScreenOverlay.hide()
                result.success(true)
            }
            "isBlockScreenShowing" -> result.success(BlockScreenOverlay.isShowing())
            "goHome" -> {
                BlockScreenOverlay.goHome(context)
                result.success(true)
            }
            "setBlockScreenStyle" -> {
                // Persist, then live-rebuild a showing wall (the setCounterStyle
                // shape). A malformed style is skipped, not a crash.
                (call.argument<Any?>("style") as? Map<*, *>)?.let {
                    store.blockScreenStyleJson = JSONObject(it).toString()
                    BlockScreenOverlay.onStyleChanged(context)
                }
                result.success(true)
            }
            "blockScreenStyle" -> result.success(jsonToMap(store.blockScreenStyleJson))
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
            // A missing/malformed flag is a no-op (like pushConfig), never a
            // silent "on": the persisted value is the user's choice.
            "setContentCounterEnabled" -> {
                val on = call.argument<Boolean>("enabled")
                    ?: return result.success(false)
                ContentCounterStore(context).enabled = on
                DetoxoAccessibilityService.instance?.contentCounter?.setEnabled(on)
                result.success(true)
            }
            "setContentBubbleEnabled" -> {
                val on = call.argument<Boolean>("enabled")
                    ?: return result.success(false)
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
                // Persist the changed surface(s), then live-re-render ONLY that
                // surface: the visible bubble via the service, every pinned
                // widget directly. A malformed surface is skipped, not a crash.
                val store = ContentCounterStore(context)
                (call.argument<Any?>("bubble") as? Map<*, *>)?.let {
                    store.bubbleStyleJson = JSONObject(it).toString()
                    DetoxoAccessibilityService.instance?.contentCounter?.onStyleChanged()
                }
                (call.argument<Any?>("widget") as? Map<*, *>)?.let {
                    store.widgetStyleJson = JSONObject(it).toString()
                    ContentCounterWidgetProvider.pushUpdate(context, store.snapshot(dateKey()))
                }
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
            // EVO-047: browsers Detoxo cannot enforce in, so the Website
            // blocker can say so instead of looking protective.
            "unsupportedBrowsers" -> {
                ioExecutor.execute {
                    val browsers = queryUnsupportedBrowsers()
                    mainHandler.post { result.success(browsers) }
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
     * Installed browsers the web blocker CANNOT enforce in: everything that
     * resolves ACTION_VIEW for http/https minus [BrowserUrlExtractor.isBrowser].
     *
     * Resolving that intent is the definitive "is a browser" test, and the
     * manifest already declares both `<queries>` intents for it, so no
     * QUERY_ALL_PACKAGES is involved. Returns `{packageName, label}` per app,
     * sorted by label; empty when everything installed is covered, and null
     * only on total failure (Dart then shows no notice rather than a wrong one).
     */
    private fun queryUnsupportedBrowsers(): List<Map<String, String>>? {
        return try {
            val pm = context.packageManager
            val seen = LinkedHashSet<String>()
            for (scheme in arrayOf("https", "http")) {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("$scheme://example.com"))
                val resolved =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
                    } else {
                        @Suppress("DEPRECATION")
                        pm.queryIntentActivities(intent, 0)
                    }
                for (info in resolved) {
                    info.activityInfo?.packageName?.let { seen.add(it) }
                }
            }
            seen
                .asSequence()
                .filter { it != context.packageName && !BrowserUrlExtractor.isBrowser(it) }
                .map { pkg ->
                    val label = try {
                        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
                    } catch (_: Throwable) {
                        pkg
                    }
                    mapOf("packageName" to pkg, "label" to label)
                }
                .sortedBy { it["label"]?.lowercase() ?: "" }
                .toList()
        } catch (_: Throwable) {
            null
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

    /** `{}` for an empty or malformed JSON object — a persisted style never fails to load. */
    private fun jsonToMap(json: String): Map<String, Any?> {
        if (json.isEmpty()) return emptyMap()
        return try {
            val o = JSONObject(json)
            val out = HashMap<String, Any?>()
            for (key in o.keys()) {
                val v = o.opt(key)
                out[key] = if (v == JSONObject.NULL) null else v
            }
            out
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    private fun isAccessibilityEnabled(): Boolean = AccessibilityCheck.isEnabled(context)

    /** One AppOps check for the whole native side — the block screen reads it too (EVO-027). */
    private fun hasUsageAccess(): Boolean = UsageQuery.hasAccess(context)

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
