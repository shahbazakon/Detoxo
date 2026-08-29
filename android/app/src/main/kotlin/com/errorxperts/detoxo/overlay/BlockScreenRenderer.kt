package com.errorxperts.detoxo.overlay

import com.errorxperts.detoxo.engine.UsageQuery
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.errorxperts.detoxo.R
import com.errorxperts.detoxo.engine.UsageLadder
import com.errorxperts.detoxo.widget.Palette
import com.errorxperts.detoxo.widget.WidgetBitmapRenderer
import com.errorxperts.detoxo.widget.withAlpha
import org.json.JSONObject
import kotlin.math.pow
import kotlin.math.roundToInt

// ── Wire shapes (file-level so the JVM test never touches an Android initializer) ──

/**
 * What the wall says. Built natively at the four trigger sites and parsed from
 * the `showBlockScreen` channel arm; [sanitised] is applied on both paths.
 *
 * `plan` carries the wire token verbatim (`CURIOUS`); the rendered label is
 * [planLabel]'s job. `todayCount` / `allowanceLeft` / `bankMs` use -1 for
 * "not applicable" so a line is skipped, never printed as 0.
 */
data class BlockScreenPayload(
    val referenceType: String,        // REEL | APP | WEBSITE
    val referenceId: String,          // platformId | package | host
    val displayName: String,          // "Instagram Reels" / app label / host
    val appLabel: String = "",        // the app under the wall ("Back to Instagram")
    val packageName: String = "",     // the app under the wall (EVO-027's opens count)
    val blockReason: String,          // PLAN | APP_BLOCK | WEB_RULE | ADULT | DAILY_LIMIT | SCHEDULE
    val plan: String = "",            // BLOCK_ALL | CURIOUS | ONE_REEL | "" (no chip)
    val allowance: Int = 1,           // the armed One Reel / Unblock count
    val todayCount: Int = -1,
    val allowanceLeft: Int = -1,
    val bankMs: Long = -1L,
    val opensToday: Int = -1,         // foreground transitions since midnight; filled late by the overlay
    val unlocksAtMs: Long = -1L,      // EVO-028: when the rule window covering this block closes
    val offersOpenApp: Boolean = true,
    val offersUnblock: Boolean = false,
) {
    /**
     * EVO-018: an adult-list hit is never named and never one tap from being
     * lifted. A plan chip only makes sense when the plan is what blocked —
     * app/web rules fire during a Pause too, when the plan token would lie.
     */
    fun sanitised(): BlockScreenPayload {
        var p = this
        if (p.blockReason == REASON_ADULT) {
            p = p.copy(displayName = "", referenceId = "", offersUnblock = false)
        }
        if (p.blockReason != REASON_PLAN) p = p.copy(plan = "")
        return p
    }

    companion object {
        const val TYPE_REEL = "REEL"
        const val TYPE_APP = "APP"
        const val TYPE_WEBSITE = "WEBSITE"
        const val REASON_PLAN = "PLAN"
        const val REASON_APP_BLOCK = "APP_BLOCK"
        const val REASON_WEB_RULE = "WEB_RULE"
        const val REASON_ADULT = "ADULT"
        const val REASON_DAILY_LIMIT = "DAILY_LIMIT"
        const val REASON_SCHEDULE = "SCHEDULE"

        /** Null when the two fields nothing can default are missing. */
        fun fromMap(m: Map<*, *>?): BlockScreenPayload? {
            if (m == null) return null
            val type = m["referenceType"] as? String ?: return null
            val reason = m["blockReason"] as? String ?: return null
            return BlockScreenPayload(
                referenceType = type,
                referenceId = m["referenceId"] as? String ?: "",
                displayName = m["displayName"] as? String ?: "",
                appLabel = m["appLabel"] as? String ?: "",
                packageName = m["packageName"] as? String ?: "",
                blockReason = reason,
                plan = m["plan"] as? String ?: "",
                allowance = (m["allowance"] as? Number)?.toInt() ?: 1,
                todayCount = (m["todayCount"] as? Number)?.toInt() ?: -1,
                allowanceLeft = (m["allowanceLeft"] as? Number)?.toInt() ?: -1,
                bankMs = (m["bankMs"] as? Number)?.toLong() ?: -1L,
                opensToday = (m["opensToday"] as? Number)?.toInt() ?: -1,
                unlocksAtMs = (m["unlocksAtMs"] as? Number)?.toLong() ?: -1L,
                offersOpenApp = m["offersOpenApp"] as? Boolean ?: true,
                offersUnblock = m["offersUnblock"] as? Boolean ?: false,
            )
        }
    }
}

/**
 * Wall appearance parsed from the JSON persisted by the Dart `BlockScreenStyle`
 * (`block_screen_style` in `detoxo_engine_prefs`). `enabled` is the wall's own
 * switch: off → the trigger sites fall back to the toast + BACK/HOME they
 * always had. Malformed JSON → defaults, never a crash.
 */
data class BlockScreenStyleSpec(
    val enabled: Boolean = true,
    val theme: String = "SYSTEM",          // SYSTEM | LIGHT | DARK
    val background: String = "GLASS_DARK", // GLASS_DARK | GLASS_BRAND | SOLID | USAGE_TINT
    val showCount: Boolean = true,
    val showOpens: Boolean = true,         // EVO-027: "Instagram opened 7 times today"
    val accentByUsage: Boolean = false,
    val backDelaySec: Int = 5,             // EVO-025: 0 = the ghost exit unlocks at once
) {
    companion object {
        fun fromJson(json: String?): BlockScreenStyleSpec {
            if (json.isNullOrEmpty()) return BlockScreenStyleSpec()
            return try {
                val o = JSONObject(json)
                BlockScreenStyleSpec(
                    enabled = o.optBoolean("enabled", true),
                    theme = o.optString("theme", "SYSTEM"),
                    background = o.optString("background", "GLASS_DARK"),
                    showCount = o.optBoolean("showCount", true),
                    showOpens = o.optBoolean("showOpens", true),
                    accentByUsage = o.optBoolean("accentByUsage", false),
                    backDelaySec = o.optInt("backDelaySec", 5).coerceIn(0, 60),
                )
            } catch (_: Throwable) {
                BlockScreenStyleSpec()
            }
        }
    }
}

/**
 * Wire token → the label the user knows. `CURIOUS` is the legacy wire for
 * Conscious and must never reach the screen; `ONE_REEL` is two user-facing
 * plans depending on the armed [allowance] (dashboard: "One Reel" for 1,
 * "Unblock" for 2+). Unknown / blank → "" (no chip).
 */
internal fun planLabel(token: String, allowance: Int): String = when (token) {
    "CURIOUS" -> "Conscious"
    "ONE_REEL" -> if (allowance <= 1) "One Reel" else "Unblock"
    "BLOCK_ALL" -> "Block All"
    "PAUSED" -> "Paused"
    else -> ""
}

/** Navy — the primary button's text on the teal / mint accent (≥ 6:1 both themes). */
private const val ON_ACCENT = 0xFF0B1326.toInt()

/** WCAG relative luminance of an ARGB colour (alpha ignored). Pure. */
private fun luminance(argb: Int): Double {
    fun channel(v: Int): Double {
        val c = v / 255.0
        return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
    }
    return 0.2126 * channel((argb shr 16) and 0xFF) +
        0.7152 * channel((argb shr 8) and 0xFF) +
        0.0722 * channel(argb and 0xFF)
}

/** WCAG contrast ratio between two opaque colours. Pure. */
internal fun contrastRatio(a: Int, b: Int): Double {
    val la = luminance(a)
    val lb = luminance(b)
    return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
}

/**
 * Text colour for a button filled with [fill]: navy where it reads best, white
 * otherwise. "Colour by usage" swaps the accent for the usage band, whose deep
 * red drops navy to 3.6:1 — white is 5.2:1 there. Pure; pinned by the JVM test.
 */
internal fun onColorFor(fill: Int): Int =
    if (contrastRatio(ON_ACCENT, fill) >= contrastRatio(0xFFFFFFFF.toInt(), fill)) ON_ACCENT else 0xFFFFFFFF.toInt()

/**
 * Where the wall's text block starts: 34 % down the screen, pulled up so it
 * clears the button column ([reservedBottom], plus [gap]) at large font
 * scales, and never above [minTop] (the cutout / status-bar area). Pure.
 */
internal fun wallTextTop(height: Int, blockHeight: Int, reservedBottom: Int, gap: Int, minTop: Int): Float =
    minOf(height * 0.34f, (height - reservedBottom - gap - blockHeight).toFloat())
        .coerceAtLeast(minTop.toFloat())

// ── Renderer ─────────────────────────────────────────────────────────────────

/**
 * Builds the wall: a Canvas-drawn backdrop (gradient + plan chip + headline +
 * reason + stat lines) with real [Button]s underneath, so TalkBack gets one
 * focusable target per action. Colours come from the home widget's palette
 * table so the Flutter preview mirrors it for free.
 *
 * ponytail: content renders on a Canvas, so the wall cannot reuse the Flutter
 * design system. Upgrade path = a Flutter-rendered wall, which costs a second
 * engine and is blocked by the single-process invariant.
 */
object BlockScreenRenderer {

    const val ACTION_GO_HOME = "GO_HOME"
    const val ACTION_OPEN_APP = "OPEN_APP"
    const val ACTION_DISMISS = "DISMISS"
    const val ACTION_UNBLOCK = "UNBLOCK"

    /**
     * EVO-050: `"UNBLOCK_15"` — the chip the user actually picked, so the
     * duration never has to survive a process hop. [ACTION_UNBLOCK] itself now
     * only reveals the row (and is still posted, so analytics keeps counting
     * the intent separately from the choice).
     */
    const val ACTION_UNBLOCK_PREFIX = "UNBLOCK_"

    /** Mirrors Dart's `unblockDurationMinutes` — one duration vocabulary. */
    val UNBLOCK_MINUTES = intArrayOf(5, 15, 30, 60)

    /** View tags the overlay uses to reach the two views it updates after build. */
    const val TAG_WALL = "wall"
    const val TAG_BACK = "back"

    internal val bold: Typeface by lazy { Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }

    fun build(
        context: Context,
        payload: BlockScreenPayload,
        spec: BlockScreenStyleSpec,
        onAction: (String) -> Unit,
    ): View {
        val dark = when (spec.theme) {
            "LIGHT" -> false
            "DARK" -> true
            else -> WidgetBitmapRenderer.isSystemDark(context)
        }
        val count = payload.todayCount.coerceAtLeast(0)
        val palette = WidgetBitmapRenderer.paletteFor(spec.background, dark, count)
        val accent = if (spec.accentByUsage && payload.todayCount >= 0) {
            UsageLadder.color(payload.todayCount)
        } else {
            palette.label
        }
        val copy = WallCopy.from(context, payload, spec)

        val root = FrameLayout(context)
        val wall = WallView(context, copy, palette, accent).apply { tag = TAG_WALL }
        root.addView(
            wall,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        val actions = buildActions(context, payload, palette, accent, onAction)
        root.addView(
            actions,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ),
        )
        // The text block must clear the button column at any font scale: the
        // column's laid-out height is what the backdrop reserves.
        actions.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ -> wall.reservedBottom = v.height }
        // The window draws under the system bars (setFitInsetsTypes(0)), so the
        // button column pads itself clear of the navigation bar / gesture area.
        val side = dp(context, 24f)
        actions.setPadding(side, 0, side, dp(context, 24f))
        root.setOnApplyWindowInsetsListener { _, insets ->
            val bottom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                insets.getInsets(WindowInsets.Type.systemBars()).bottom
            } else {
                @Suppress("DEPRECATION")
                insets.systemWindowInsetBottom
            }
            actions.setPadding(side, 0, side, bottom + dp(context, 24f))
            insets
        }
        return root
    }

    private fun buildActions(
        context: Context,
        p: BlockScreenPayload,
        palette: Palette,
        accent: Int,
        onAction: (String) -> Unit,
    ): LinearLayout {
        val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val gap = dp(context, 12f)
        fun add(button: Button) {
            column.addView(
                button,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = if (column.childCount == 0) 0 else gap },
            )
        }
        val res = context.resources
        if (p.referenceType == BlockScreenPayload.TYPE_APP) {
            // The app is already HOME-bounced: "Got it" just takes the wall down.
            add(button(context, res.getString(R.string.wall_got_it), Style.PRIMARY, palette, accent) {
                onAction(ACTION_DISMISS)
            })
        } else {
            add(button(context, res.getString(R.string.wall_go_home), Style.PRIMARY, palette, accent) {
                onAction(ACTION_GO_HOME)
            })
        }
        if (p.offersOpenApp) {
            add(button(context, res.getString(R.string.wall_open_app), Style.SECONDARY, palette, accent) {
                onAction(ACTION_OPEN_APP)
            })
        }
        if (p.referenceType != BlockScreenPayload.TYPE_APP) {
            // Detoxo blocks reels, not apps: the way back into the app's other
            // screens (DMs, the previous tab) is a first-class exit.
            val label = p.appLabel.ifBlank { p.displayName }.ifBlank { res.getString(R.string.wall_this_app) }
            add(button(context, res.getString(R.string.wall_back_to, label), Style.GHOST, palette, accent) {
                onAction(ACTION_DISMISS)
            }.apply { tag = TAG_BACK }) // the overlay counts it down (EVO-025) / relabels it (EVO-026)
        }
        if (p.offersUnblock) {
            // EVO-050: the durations are asked HERE, not after a launch into
            // Detoxo. Pressing a button on a wall that is blocking Instagram
            // used to take the user out of Instagram and into another app — the
            // outcome the wall was already trying to produce — and every defect
            // on that hand-off path (a key with no TTL, a tap eaten by the PIN
            // screen, a sheet with no Navigator) existed only because the
            // question was asked somewhere other than where it was raised.
            val chips = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                visibility = View.GONE
            }
            for (m in UNBLOCK_MINUTES) {
                chips.addView(
                    button(
                        context,
                        res.getString(R.string.wall_unblock_minutes, m),
                        Style.GHOST,
                        palette,
                        accent,
                    ) { onAction("$ACTION_UNBLOCK_PREFIX$m") },
                    LinearLayout.LayoutParams(
                        0,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        1f,
                    ).apply { if (chips.childCount > 0) marginStart = dp(context, 8f) },
                )
            }
            // `lateinit` so the trigger can hide itself: the row replaces it in
            // place rather than pushing the exits around, which would move a
            // button under a finger already travelling towards it.
            lateinit var trigger: Button
            trigger = button(
                context,
                res.getString(R.string.wall_unblock),
                Style.GHOST,
                palette,
                accent,
            ) {
                trigger.visibility = View.GONE
                chips.visibility = View.VISIBLE
                onAction(ACTION_UNBLOCK)
            }
            add(trigger)
            column.addView(
                chips,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = gap },
            )
        }
        return column
    }

    private enum class Style { PRIMARY, SECONDARY, GHOST }

    private fun button(
        context: Context,
        text: String,
        style: Style,
        palette: Palette,
        accent: Int,
        onClick: () -> Unit,
    ): Button {
        val radius = dp(context, 14f).toFloat()
        val fill = when (style) {
            Style.PRIMARY -> accent
            Style.SECONDARY -> withAlpha(palette.today, 0x1F)
            Style.GHOST -> 0
        }
        // Navy on the teal/mint accent stays ≥ 6:1 in both themes (white would
        // not); on a deep-red usage band it is white that reads — onColorFor picks.
        val textColor = if (style == Style.PRIMARY) onColorFor(accent) else palette.today
        val shape = GradientDrawable().apply {
            cornerRadius = radius
            setColor(fill)
            if (style == Style.SECONDARY) setStroke(dp(context, 1f), palette.stroke)
        }
        val ripple = RippleDrawable(
            ColorStateList.valueOf(withAlpha(palette.today, 0x33)),
            shape,
            GradientDrawable().apply { cornerRadius = radius; setColor(-0x1) },
        )
        return Button(context).apply {
            this.text = text
            contentDescription = text
            isAllCaps = false
            typeface = bold
            textSize = 16f
            setTextColor(textColor)
            background = ripple
            stateListAnimator = null
            minHeight = dp(context, 48f)
            minimumHeight = dp(context, 48f)
            val h = dp(context, 20f)
            val v = dp(context, 12f)
            setPadding(h, v, h, v)
            isFocusable = true
            setOnClickListener { onClick() }
        }
    }

    private fun dp(context: Context, v: Float): Int =
        (v * context.resources.displayMetrics.density).roundToInt()
}

/** The wall's resolved strings — computed once, drawn by [WallView]. */
internal data class WallCopy(
    val chip: String,
    val headline: String,
    val reason: String,
    val stats: List<String>,
) {
    companion object {
        fun from(context: Context, p: BlockScreenPayload, spec: BlockScreenStyleSpec): WallCopy {
            val res = context.resources
            val adult = p.blockReason == BlockScreenPayload.REASON_ADULT
            val name = p.displayName.ifBlank { res.getString(R.string.wall_this_app) }
            val headline = if (adult) {
                res.getString(R.string.toast_blocked_adult)
            } else {
                res.getString(R.string.toast_blocked, name)
            }
            val reason = when (p.blockReason) {
                BlockScreenPayload.REASON_PLAN -> when (p.plan) {
                    "CURIOUS" -> res.getString(R.string.wall_reason_conscious)
                    "ONE_REEL" -> if (p.allowance <= 1) {
                        res.getString(R.string.wall_reason_one_reel)
                    } else {
                        res.getString(R.string.wall_reason_unblock, p.allowance)
                    }
                    else -> res.getString(R.string.wall_reason_block_all)
                }
                BlockScreenPayload.REASON_APP_BLOCK -> res.getString(R.string.wall_reason_app_block)
                BlockScreenPayload.REASON_WEB_RULE -> res.getString(R.string.wall_reason_web_rule)
                BlockScreenPayload.REASON_ADULT -> res.getString(R.string.wall_reason_adult)
                // EVO-028: a rule wall names its own release time when it has
                // one, so the wall is a decision ("come back after work") and
                // not a dead end. `unlocksAtMs` is -1 / 0 when there is nothing
                // to name — the daily reel meter has no edge.
                BlockScreenPayload.REASON_DAILY_LIMIT -> if (p.unlocksAtMs > 0L) {
                    res.getString(R.string.wall_reason_daily_limit_until, clockAt(context, p.unlocksAtMs))
                } else {
                    res.getString(R.string.wall_reason_daily_limit)
                }
                BlockScreenPayload.REASON_SCHEDULE -> if (p.unlocksAtMs > 0L) {
                    res.getString(R.string.wall_reason_schedule_until, clockAt(context, p.unlocksAtMs))
                } else {
                    res.getString(R.string.wall_reason_schedule)
                }
                else -> ""
            }
            val stats = ArrayList<String>(2)
            if (spec.showCount && p.todayCount >= 0 && p.referenceType == BlockScreenPayload.TYPE_REEL) {
                stats += res.getQuantityString(R.plurals.wall_count_today, p.todayCount, p.todayCount)
            }
            if (p.bankMs >= 0L) {
                stats += res.getString(R.string.wall_bank, mmss(p.bankMs))
            } else if (p.allowanceLeft >= 0) {
                stats += res.getQuantityString(R.plurals.wall_allowance_left, p.allowanceLeft, p.allowanceLeft)
            }
            // A payload that already carries the opens count (the editor's
            // preview) renders it here; a live wall gets it late via
            // WallView.extraStats once the usage queries return (EVO-027, EVO-034).
            if (spec.showOpens && p.opensToday >= 0 && p.appLabel.isNotBlank()) {
                stats += opensLine(context, p.appLabel, p.opensToday)
            }
            return WallCopy(
                chip = planLabel(p.plan, p.allowance),
                headline = headline,
                reason = reason,
                stats = stats,
            )
        }

        /** "1h 10m today in Instagram" (EVO-034) — what the reach cost. */
        fun timeTodayLine(context: Context, appLabel: String, ms: Long): String =
            context.resources.getString(
                R.string.wall_time_today, UsageQuery.formatHm(ms), appLabel,
            )

        /** "Instagram opened 7 times today". */
        fun opensLine(context: Context, appLabel: String, opens: Int): String =
            context.resources.getQuantityString(R.plurals.wall_opens_today, opens, appLabel, opens)

        private fun mmss(ms: Long): String {
            val total = (ms / 1000L).coerceAtLeast(0L)
            return "%d:%02d".format(total / 60L, total % 60L)
        }

        /**
         * Wall clock for [ms] in the DEVICE's 12/24-hour setting — the same
         * promise the Dart side keeps (`core/utils/clock_format.dart`), so a
         * rule picked as "5:30 PM" is never read back as "17:30".
         */
        private fun clockAt(context: Context, ms: Long): String =
            android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(ms))
    }
}

/**
 * The Canvas backdrop: vertical gradient, then a text block anchored at ~38 %
 * of the height (clear of any cutout, above the button column). All sizes in
 * dp; text wraps with [StaticLayout] because app labels and hosts are long.
 *
 * Contrast (both themes, see the Flutter mirror): headline / stats in
 * `textPrimary` (≥ 16:1 dark, ≥ 16:1 light), reason in `textMuted` (≥ 9:1
 * dark, ≥ 5.5:1 light); the accent is used only as a chip fill and the
 * primary-button fill, never for body text.
 */
internal class WallView(
    context: Context,
    private val copy: WallCopy,
    private val palette: Palette,
    private val accent: Int,
) : View(context) {

    /** The button column's laid-out height — the text block never draws into it. */
    var reservedBottom: Int = 0
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    /**
     * Stat lines that arrive after build: EVO-027's opens count and EVO-034's
     * time-today. A list, not one string, so each renders as its own block —
     * the same shape as [WallCopy.stats].
     */
    var extraStats: List<String> = emptyList()
        set(value) {
            if (field == value) return
            field = value
            refreshDescription()
            invalidate()
        }

    private val density = resources.displayMetrics.density
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val chipPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(accent, 0x33) }
    private val chipStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f).toFloat()
        color = withAlpha(accent, 0x99)
    }
    private val chipText = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.today
        textSize = sp(13f)
        typeface = BlockScreenRenderer.bold
        letterSpacing = 0.06f
    }
    private val headline = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.today
        textSize = sp(28f)
        typeface = BlockScreenRenderer.bold
    }
    private val reason = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.total
        textSize = sp(16f)
    }
    private val stat = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.today
        textSize = sp(18f)
        typeface = BlockScreenRenderer.bold
    }

    init {
        refreshDescription()
    }

    private fun stats(): List<String> = copy.stats + extraStats

    private fun refreshDescription() {
        contentDescription = listOf(copy.chip, copy.headline, copy.reason)
            .plus(stats())
            .filter { it.isNotBlank() }
            .joinToString(". ")
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        fill.shader = LinearGradient(
            0f, 0f, 0f, h.toFloat(),
            palette.bgTop, palette.bgBottom, Shader.TileMode.CLAMP,
        )
    }

    override fun onDraw(canvas: Canvas) {
        val w = width
        val h = height
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), fill)

        val side = dp(28f)
        val maxWidth = (w - side * 2).coerceAtLeast(1)
        val chipH = dp(32f)
        val chipBlock = if (copy.chip.isNotBlank()) chipH + dp(18f) else 0

        // Measure first, so the whole block can be pulled up clear of the
        // button column when a large font scale makes it tall.
        val blocks = ArrayList<Pair<StaticLayout, Int>>(6) // layout + the gap below it
        blocks += layout(copy.headline, headline, maxWidth) to dp(10f)
        if (copy.reason.isNotBlank()) blocks += layout(copy.reason, reason, maxWidth) to dp(18f)
        for (line in stats()) blocks += layout(line, stat, maxWidth) to dp(6f)
        val blockHeight = chipBlock + blocks.sumOf { it.first.height + it.second }
        var y = wallTextTop(h, blockHeight, reservedBottom, dp(16f), dp(48f))

        if (copy.chip.isNotBlank()) {
            val padH = dp(14f)
            val textW = chipText.measureText(copy.chip)
            val rect = RectF(side.toFloat(), y, side + textW + padH * 2, y + chipH)
            canvas.drawRoundRect(rect, chipH / 2f, chipH / 2f, chipPaint)
            canvas.drawRoundRect(rect, chipH / 2f, chipH / 2f, chipStroke)
            val fm = chipText.fontMetrics
            canvas.drawText(
                copy.chip,
                side + padH.toFloat(),
                y + chipH / 2f - (fm.ascent + fm.descent) / 2f,
                chipText,
            )
            y += chipBlock
        }
        for ((layout, gap) in blocks) {
            canvas.save()
            canvas.translate(side.toFloat(), y)
            layout.draw(canvas)
            canvas.restore()
            y += layout.height + gap
        }
    }

    /** Wrapped text, at most three lines (app labels and hosts are long). */
    private fun layout(text: String, paint: TextPaint, maxWidth: Int): StaticLayout =
        StaticLayout.Builder.obtain(text, 0, text.length, paint, maxWidth)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .setMaxLines(3)
            .build()

    private fun dp(v: Float): Int = (v * density).roundToInt()
    private fun sp(v: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, resources.displayMetrics)
}
