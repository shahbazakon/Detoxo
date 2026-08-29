package com.errorxperts.detoxo.overlay

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.LinearLayout
import android.widget.TextView
import com.errorxperts.detoxo.R
import kotlin.math.roundToInt

/**
 * The soft nudge card: a small bottom-anchored overlay that says how long the
 * user has been in the app and then goes away by itself.
 *
 * Deliberately NOT the block screen. [BlockScreenOverlay] is one full-screen
 * window that swallows every touch and defends the back gesture, because a
 * wall's whole job is to interrupt; a nudge's job is the opposite — it must
 * never take a tap the user meant for the feed underneath. So this is its own
 * window: WRAP_CONTENT, bottom gravity, and `FLAG_NOT_TOUCH_MODAL`, which
 * hands every touch outside the card straight through to the app below. The
 * two overlays are independent, and the service suppresses this one whenever
 * the wall is up (two interventions for one moment is worse than either).
 *
 * The permission handling, the recheck throttle and the teardown are the ones
 * [ContentCounterBubble] already proved — same window family, same failure
 * modes. All view work runs on the main Looper.
 */
object NudgeOverlay {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var view: View? = null
    private var warnedNoOverlay = false
    private var overlayDeniedAtMs = 0L

    /** Re-arms the tracker when the card goes — see `NudgeTracker.onDismissed`. */
    private var onDismissed: (() -> Unit)? = null

    private val autoDismiss = Runnable { hide() }

    fun isShowing(): Boolean = view != null

    /**
     * Raise the card over [label] ("Instagram") after [elapsedMs] in it. False
     * when the overlay grant is missing — the nudge is advisory, so a missing
     * grant is simply a silent no-op rather than a permission prompt mid-scroll.
     */
    fun show(
        context: Context,
        label: String,
        elapsedMs: Long,
        onDismissed: () -> Unit,
        onLeave: () -> Unit = {},
    ): Boolean {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { show(context, label, elapsedMs, onDismissed, onLeave) }
            return true
        }
        // Remember a denial briefly: without the grant every nudge would be a
        // binder round-trip to AppOps. A fresh grant is picked up on the first
        // attempt after OVERLAY_RECHECK_MS.
        val t = SystemClock.uptimeMillis()
        if (t - overlayDeniedAtMs < OVERLAY_RECHECK_MS) return false
        if (!Settings.canDrawOverlays(context)) {
            overlayDeniedAtMs = t
            if (!warnedNoOverlay) {
                warnedNoOverlay = true
                Log.w(TAG, "nudge suppressed: overlay permission missing")
            }
            return false
        }
        overlayDeniedAtMs = 0L
        detach() // never stack two cards

        this.onDismissed = onDismissed
        val card = buildCard(context, label, elapsedMs, onLeave)
        val lp = WindowManager.LayoutParams(
            cardWidth(context),
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            // NOT_TOUCH_MODAL is the whole passthrough contract: touches outside
            // the card's own bounds go to the app underneath, so the user can
            // keep scrolling while it is up.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = dp(context, BOTTOM_MARGIN_DP)
        }
        return try {
            wm(context).addView(card, lp)
            view = card
            card.alpha = 0f
            card.translationY = dp(context, 24f).toFloat()
            card.animate()
                .alpha(1f).translationY(0f)
                .setInterpolator(DecelerateInterpolator())
                .setDuration(220)
                .start()
            mainHandler.postDelayed(autoDismiss, VISIBLE_MS)
            true
        } catch (t2: Throwable) {
            Log.w(TAG, "addView failed: ${t2.message}")
            this.onDismissed = null
            false
        }
    }

    /** Take the card away (auto-dismiss, user tap, or the wall going up). */
    fun hide() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { hide() }
            return
        }
        val had = view != null
        detach()
        if (had) onDismissed?.invoke()
        onDismissed = null
    }

    /** Synchronous teardown (main thread only), no callback. */
    private fun detach() {
        mainHandler.removeCallbacks(autoDismiss)
        val v = view ?: return
        view = null
        try {
            wm(v.context).removeView(v)
        } catch (_: Throwable) {
        }
    }

    private fun wm(context: Context) =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    // ── The card ──────────────────────────────────────────────────────────────

    private fun buildCard(
        context: Context,
        label: String,
        elapsedMs: Long,
        onLeave: () -> Unit,
    ): View {
        val minutes = (elapsedMs / 60_000L).toInt().coerceAtLeast(1)
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(context, 20f).toFloat()
                setColor(CARD_BG)
                setStroke(dp(context, 1f), CARD_STROKE)
            }
            elevation = dp(context, 8f).toFloat()
            val padH = dp(context, 18f)
            val padV = dp(context, 14f)
            setPadding(padH, padV, dp(context, 10f), padV)
            // Tapping the card itself dismisses it, so the user never has to aim
            // for the ✕ mid-scroll. Labelled because that makes the container
            // an activatable target in its own right (the wall's card does the
            // same in BlockScreenRenderer).
            contentDescription = context.getString(
                R.string.nudge_card_a11y,
                label,
                minutes,
            )
            setOnClickListener { hide() }
        }

        val lines = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f)
        }
        lines.addView(
            TextView(context).apply {
                text = context.getString(R.string.nudge_title, label, minutes)
                setTextColor(TEXT_ACCENT)
                setTypeface(Typeface.DEFAULT_BOLD)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            },
        )
        lines.addView(
            TextView(context).apply {
                text = context.getString(R.string.nudge_body)
                setTextColor(TEXT_MUTED)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            },
        )
        row.addView(lines)

        // The one way out. Without it the card is a dead end: it tells the user
        // they have been somewhere 15 minutes and offers only "dismiss", which
        // is the opposite of Detoxo's in-the-moment pitch. The ENGINE still
        // never blocks — this is the user leaving, on their own tap.
        row.addView(
            TextView(context).apply {
                text = context.getString(R.string.nudge_leave)
                setTextColor(TEXT_ACCENT)
                setTypeface(Typeface.DEFAULT_BOLD)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.CENTER
                background = GradientDrawable().apply {
                    cornerRadius = dp(context, 14f).toFloat()
                    setColor(ACTION_BG)
                }
                val h = dp(context, 14f)
                setPadding(h, dp(context, 8f), h, dp(context, 8f))
                minHeight = dp(context, 48f)
                minimumHeight = dp(context, 48f)
                isFocusable = true
                setOnClickListener {
                    hide()
                    onLeave()
                }
            },
        )

        row.addView(
            TextView(context).apply {
                text = "✕"
                contentDescription = context.getString(R.string.nudge_dismiss)
                setTextColor(TEXT_MUTED)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                gravity = Gravity.CENTER
                // 48 dp is Android's minimum touch target — the wall's buttons
                // take the same floor (BlockScreenRenderer.button).
                val min = dp(context, 48f)
                minWidth = min
                minHeight = min
                minimumWidth = min
                minimumHeight = min
                isFocusable = true
                setOnClickListener { hide() }
            },
        )

        return row
    }

    /** A fixed share of the screen — the snackbar shape, and a long app label
     *  can never stretch the card edge to edge. */
    private fun cardWidth(context: Context) =
        (context.resources.displayMetrics.widthPixels * 0.88f).roundToInt()

    private fun dp(context: Context, v: Float) =
        (v * context.resources.displayMetrics.density).roundToInt()

    private const val WRAP = LinearLayout.LayoutParams.WRAP_CONTENT
    private const val TAG = "NudgeOverlay"

    /** How long the card stays up before it takes itself away. */
    private const val VISIBLE_MS = 6_000L

    /** After a denied overlay check, skip the binder re-check for this long. */
    private const val OVERLAY_RECHECK_MS = 5_000L

    /** Above the gesture bar, clear of most bottom navigation. */
    private const val BOTTOM_MARGIN_DP = 96f

    // The brand's dark-glass card, matching the wall and the counter bubble.
    private val CARD_BG = Color.parseColor("#F0141B2E")
    private val CARD_STROKE = Color.parseColor("#5544E2CD")
    private val TEXT_ACCENT = Color.parseColor("#FF44E2CD")
    private val TEXT_MUTED = Color.parseColor("#FFB8C0D9")
    private val ACTION_BG = Color.parseColor("#2244E2CD")
}
