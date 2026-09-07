package com.errorxperts.detoxo.overlay

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import com.errorxperts.detoxo.R
import com.errorxperts.detoxo.accessibility.DetoxoAccessibilityService
import com.errorxperts.detoxo.engine.ConfigStore
import com.errorxperts.detoxo.engine.ServiceEventBus
import com.errorxperts.detoxo.engine.UsageQuery
import java.util.concurrent.Executors
import kotlin.math.max

/** `FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL | FLAG_LAYOUT_IN_SCREEN | FLAG_LAYOUT_NO_LIMITS` (= 808). */
internal fun overlayFlags(): Int =
    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS

/**
 * Width of each edge strip that physically swallows the back gesture. On
 * API 30+ 1.5× the wider system-gesture inset; below, 50 dp. Pure — pinned
 * by `BlockScreenGeometryTest`.
 */
internal fun stripWidthPx(sdkInt: Int, gestureLeftPx: Int, gestureRightPx: Int, density: Float): Int =
    if (sdkInt >= Build.VERSION_CODES.R) {
        (max(gestureLeftPx, gestureRightPx) * 1.5f).toInt()
    } else {
        (density * 50f).toInt()
    }

/**
 * The intervention wall: one full-screen `TYPE_APPLICATION_OVERLAY` window
 * raised at the moment of a block, plus two edge strips that swallow the back
 * gesture. Held as an object so the accessibility service (its four trigger
 * sites) and `CommandHandler` (a style preview with the service possibly dead)
 * share one window and can never stack two.
 *
 * Fail-safe by construction: no overlay grant → [show] returns false and the
 * trigger site keeps its toast + BACK/HOME; a `BadTokenException` (grant
 * revoked mid-show) ejects to home and tears down. Every public call runs on
 * the main looper; the Android members are lazy so a JVM test can load the
 * class for [stripWidthPx] / [overlayFlags].
 *
 * After the add, the overlay owns two late touches on the built view: the
 * ghost exit's countdown / relabel (EVO-025 / EVO-026, through
 * [BlockScreenRenderer.TAG_BACK]) and the "opened N times today" line from the
 * usage layer (EVO-027, through [BlockScreenRenderer.TAG_WALL]).
 *
 * ponytail: strips are two fixed edge windows and touch-only — a bottom-edge
 * back gesture, a free-form window, or an accessibility global BACK still
 * routes around them. Upgrade path = a third bottom strip behind a per-OEM
 * flag.
 */
object BlockScreenOverlay {

    private const val TAG = "BlockScreen"

    /** After a denied overlay check, skip the binder re-check for this long. */
    private const val OVERLAY_RECHECK_MS = 5000L

    /** The ghost exit's countdown cadence. */
    private const val TICK_MS = 1000L

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    /** EVO-027's usage query: one idle thread, created on first use. */
    private val io by lazy { Executors.newSingleThreadExecutor() }

    private var app: Context? = null
    private var store: ConfigStore? = null
    private var mainView: View? = null
    private val strips = ArrayList<View>(2)
    private var current: BlockScreenPayload? = null
    private var over: Set<String> = emptySet()
    private var raisedOver = ""
    private var preview = false
    private var warnedNoOverlay = false
    private var overlayDeniedAtMs = 0L

    // The ghost exit ("Back to Instagram"): counted down after the add and
    // relabelled "Dismiss" once the foreground has left the app it names.
    private var backButton: Button? = null
    private var backLabel: CharSequence = ""
    private var countdownLeft = 0
    private val countdownTick = object : Runnable {
        override fun run() {
            countdownLeft--
            renderBack()
            if (countdownLeft > 0) mainHandler.postDelayed(this, TICK_MS)
        }
    }

    /**
     * Raises the wall for [payload] over the packages in [staysOver] (the app it
     * was raised for [raisedOver]; plus wherever the BACK / HOME that follows
     * can land). Returns true when the window is up (already up counts), false
     * when the wall is switched off, the grant is missing, or the add failed —
     * the caller then keeps its legacy toast. A standing wall takes a newer
     * payload (a drained bank, a fresh count) by rebuilding in place. Main
     * thread only; a call from another thread is re-posted and reports false.
     * The Appearance switch is skipped per [WallPolicy.bypassesSwitch] (a
     * forced block, or a reel wall in the Block screen mode) — decided here
     * from the payload so [onStyleChanged] reaches the same answer; a preview
     * always honours the switch. The overlay grant is never skipped.
     */
    fun show(
        context: Context,
        payload: BlockScreenPayload,
        staysOver: Set<String>,
        preview: Boolean = false,
        raisedOver: String = "",
    ): Boolean {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { show(context, payload, staysOver, preview, raisedOver) }
            return false
        }
        val ctx = context.applicationContext
        app = ctx

        // Steady state first — no prefs read, no JSON parse, no binder call
        // while the same wall is alive. The attach check recovers from an
        // overlay revoke → re-grant cycle.
        val existing = mainView
        if (existing != null) {
            if (existing.isAttachedToWindow && sameWall(payload, current)) {
                over = over + staysOver
                return true
            }
            detach()
        }
        val store = storeFor(ctx)
        val spec = BlockScreenStyleSpec.fromJson(store.blockScreenStyleJson)
        if (!spec.enabled &&
            (preview || !WallPolicy.bypassesSwitch(payload, store.defaultBlockMode))
        ) {
            return false
        }

        val t = SystemClock.uptimeMillis()
        if (t - overlayDeniedAtMs < OVERLAY_RECHECK_MS) return false
        if (!Settings.canDrawOverlays(ctx)) {
            overlayDeniedAtMs = t
            if (!warnedNoOverlay) {
                warnedNoOverlay = true
                Log.w(TAG, "wall suppressed: overlay permission missing")
            }
            return false
        }
        overlayDeniedAtMs = 0L

        val view = BlockScreenRenderer.build(ctx, payload, spec) { action -> onAction(ctx, action) }
        view.isClickable = true
        view.setOnTouchListener { _, _ -> true } // swallow every stray touch
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            overlayFlags(),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                setFitInsetsTypes(0) // draw under the system bars
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        try {
            wm(ctx).addView(view, lp)
        } catch (e: WindowManager.BadTokenException) {
            // The grant was revoked between the check and the add: eject so
            // the user is not left on the blocked surface, then reset. A
            // preview has no blocked surface — the user is in the style editor.
            Log.w(TAG, "addView refused (bad token): ${e.message}")
            if (!preview) goHome(ctx)
            detach()
            return false
        } catch (t: Throwable) {
            Log.w(TAG, "addView failed: ${t.message}")
            return false
        }
        mainView = view
        current = payload
        over = staysOver
        this.raisedOver = raisedOver
        this.preview = preview
        applyGestureDefence(ctx, view)
        armBackCountdown(view, spec.backDelaySec)
        loadOpens(ctx, payload, spec)
        return true
    }

    fun hide() = runOnMain { detach() }

    fun isShowing(): Boolean = mainView != null

    /** Whether the wall was raised over [pkg] (the hide rule keeps it up). */
    fun staysOver(pkg: String): Boolean = pkg in over

    /**
     * The foreground moved within the stays-over set (EVO-026). Once it has
     * left the app the wall was raised over, "Back to Instagram" would promise
     * a return it cannot make, so the ghost exit reads "Dismiss" from then on.
     */
    fun onForeground(pkg: String) = runOnMain {
        if (mainView == null || raisedOver.isEmpty() || pkg == raisedOver) return@runOnMain
        val dismiss = app?.getString(R.string.wall_dismiss) ?: return@runOnMain
        if (backLabel == dismiss) return@runOnMain
        backLabel = dismiss
        renderBack()
    }

    /** Rebuilds a showing wall with the freshly persisted style; no-op otherwise. */
    fun onStyleChanged(context: Context) = runOnMain {
        val p = current ?: return@runOnMain
        val o = over
        val pv = preview
        val r = raisedOver
        detach()
        show(context, p, o, pv, r)
    }

    /** Ejects to the launcher. Works from any Context — no Activity, no service needed. */
    fun goHome(context: Context) {
        try {
            context.startActivity(
                Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "goHome failed: ${t.message}")
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /** The same block, ignoring the opens count the overlay fills in late. */
    private fun sameWall(a: BlockScreenPayload, b: BlockScreenPayload?): Boolean =
        b != null && a.copy(opensToday = -1) == b.copy(opensToday = -1)

    private fun onAction(context: Context, action: String) {
        val p = current ?: return
        ServiceEventBus.post(
            "blockScreenAction",
            mapOf(
                "action" to action,
                "referenceType" to p.referenceType,
                "referenceId" to p.referenceId,
                "preview" to preview,
            ),
        )
        when (action) {
            BlockScreenRenderer.ACTION_GO_HOME -> {
                detach()
                goHome(context)
            }
            BlockScreenRenderer.ACTION_OPEN_APP -> {
                detach()
                launchDetoxo(context)
            }
            BlockScreenRenderer.ACTION_DISMISS -> detach()
            // EVO-050: the trigger only reveals the duration row (the renderer
            // does that itself). Nothing is written and the wall stays up —
            // this arm exists so the *intent* is still posted for analytics,
            // separately from the choice.
            BlockScreenRenderer.ACTION_UNBLOCK -> Unit
            else -> if (action.startsWith(BlockScreenRenderer.ACTION_UNBLOCK_PREFIX)) {
                onUnblockPicked(context, p, action, preview = preview)
            }
        }
    }

    /**
     * EVO-050: the user picked a duration ON the wall. The grant is written
     * natively and enforced on the next event — no app switch, no PIN, no
     * launch that can fail silently.
     *
     * Dart still owns the canonical list: [ConfigStore.appendGrant] also
     * records the row for `takeNativeGrants`, which the next resume folds into
     * Hive. If that write fails we fall back to M8's hand-off (arm the pending
     * intent and launch Detoxo) rather than dropping the tap — the button must
     * never do nothing.
     *
     * `preview` never writes: the style editor's sample wall must not arm a
     * real unblock.
     */
    private fun onUnblockPicked(
        context: Context,
        p: BlockScreenPayload,
        action: String,
        preview: Boolean,
    ) {
        val minutes = action.removePrefix(BlockScreenRenderer.ACTION_UNBLOCK_PREFIX).toIntOrNull()
        if (preview || p.referenceId.isEmpty() || minutes == null || minutes <= 0) {
            detach()
            return
        }
        val store = storeFor(context)
        val endMs = System.currentTimeMillis() + minutes * 60_000L
        if (store.appendGrant(p.referenceType, p.referenceId, endMs)) {
            DetoxoAccessibilityService.instance?.refreshTemporaryUnblocks()
            detach()
            return
        }
        store.setPendingUnblock(p.referenceType, p.referenceId, System.currentTimeMillis())
        detach()
        launchDetoxo(context)
    }

    // ── EVO-025: the ghost exit counts down before it unlocks ────────────────

    private fun armBackCountdown(root: View, seconds: Int) {
        val b = root.findViewWithTag<Button>(BlockScreenRenderer.TAG_BACK) ?: return
        backButton = b
        backLabel = b.text
        countdownLeft = seconds
        renderBack()
        if (seconds > 0) mainHandler.postDelayed(countdownTick, TICK_MS)
    }

    private fun renderBack() {
        val b = backButton ?: return
        val locked = countdownLeft > 0
        b.isEnabled = !locked
        b.alpha = if (locked) 0.55f else 1f
        val text = if (locked) {
            app?.getString(R.string.wall_countdown, backLabel, countdownLeft) ?: backLabel
        } else {
            backLabel
        }
        b.text = text
        b.contentDescription = text
    }

    // ── EVO-027: "Instagram opened 7 times today", from the usage layer ──────

    private fun loadOpens(ctx: Context, payload: BlockScreenPayload, spec: BlockScreenStyleSpec) {
        if (!spec.showOpens || payload.opensToday >= 0) return
        if (payload.packageName.isBlank() || payload.appLabel.isBlank()) return
        io.execute {
            // Grant check and both queries off the main thread; no grant → no
            // line, no error. One pass so the wall never paints twice.
            val stats = runCatching {
                if (UsageQuery.hasAccess(ctx)) {
                    UsageQuery.opensToday(ctx, payload.packageName) to
                        UsageQuery.timeTodayMs(ctx, payload.packageName)
                } else {
                    -1 to 0L
                }
            }.getOrDefault(-1 to 0L)
            val (opens, timeMs) = stats
            if (opens >= 0) mainHandler.post { setOpens(ctx, payload, opens, timeMs) }
        }
    }

    private fun setOpens(ctx: Context, payload: BlockScreenPayload, opens: Int, timeMs: Long) {
        val c = current ?: return
        if (!sameWall(payload, c)) return // the wall moved on meanwhile
        current = c.copy(opensToday = opens)
        // EVO-034: the cost sits under the count. Only when there is a real
        // figure — "0m today" beside a block reads as a bug, not a fact.
        val lines = buildList {
            add(WallCopy.opensLine(ctx, payload.appLabel, opens))
            if (timeMs >= 60000L) add(WallCopy.timeTodayLine(ctx, payload.appLabel, timeMs))
        }
        mainView?.findViewWithTag<WallView>(BlockScreenRenderer.TAG_WALL)?.extraStats = lines
    }

    // ── Gesture defence ──────────────────────────────────────────────────────

    /**
     * Both mechanisms are required: the system clamps exclusion rects to a
     * maximum height, and strips alone leave some OEM shells still reading the
     * gesture. The exclusion rect follows every layout pass (first layout,
     * rotation, fold), not just the first.
     */
    private fun applyGestureDefence(context: Context, view: View) {
        view.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ -> applyExclusion(v) }

        val density = context.resources.displayMetrics.density
        var left = 0
        var right = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val insets = wm(context).currentWindowMetrics.windowInsets
                    .getInsets(WindowInsets.Type.systemGestures())
                left = insets.left
                right = insets.right
            } catch (_: Throwable) {
            }
        }
        val width = stripWidthPx(Build.VERSION.SDK_INT, left, right, density)
        if (width <= 0) return // three-button navigation: nothing to defend
        for (g in intArrayOf(Gravity.TOP or Gravity.START, Gravity.TOP or Gravity.END)) {
            val strip = View(context).apply {
                isClickable = true
                setOnTouchListener { _, _ -> true }
            }
            val lp = WindowManager.LayoutParams(
                width,
                WindowManager.LayoutParams.MATCH_PARENT,
                overlayType(),
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = g }
            try {
                wm(context).addView(strip, lp)
                strips += strip
            } catch (t: Throwable) {
                Log.w(TAG, "strip addView failed: ${t.message}")
            }
        }
    }

    private fun applyExclusion(view: View) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        if (!view.isAttachedToWindow || view.width == 0) return
        view.systemGestureExclusionRects = listOf(Rect(0, 0, view.width, view.height))
    }

    private fun detach() {
        mainHandler.removeCallbacks(countdownTick)
        backButton = null
        backLabel = ""
        countdownLeft = 0
        val ctx = app
        val wm = ctx?.let { wm(it) }
        mainView?.let { v ->
            try {
                wm?.removeView(v)
            } catch (_: IllegalArgumentException) {
            }
        }
        for (s in strips) {
            try {
                wm?.removeView(s)
            } catch (_: IllegalArgumentException) {
            }
        }
        strips.clear()
        mainView = null
        current = null
        over = emptySet()
        raisedOver = ""
        preview = false
    }

    private fun storeFor(context: Context): ConfigStore =
        store ?: ConfigStore(context).also { store = it }

    private fun wm(context: Context): WindowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }
}
