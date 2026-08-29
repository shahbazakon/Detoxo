package com.errorxperts.detoxo.widget

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import com.errorxperts.detoxo.engine.UsageLadder
import kotlin.math.roundToInt
import org.json.JSONObject

/**
 * Canvas-draws the home-screen widget to a bitmap so it can honour any glass
 * background / theme / density chosen by the user and match the in-app
 * `WidgetPreview` pixel-for-pixel. The band color comes from [UsageLadder]
 * (shared with the bubble + previews).
 */
object WidgetBitmapRenderer {

    fun render(
        context: Context,
        wPx: Int,
        hPx: Int,
        styleJson: String,
        today: Int,
        total: Int,
    ): Bitmap {
        val w = wPx.coerceIn(1, MAX_PX)
        val h = hPx.coerceIn(1, MAX_PX)
        val spec = WidgetStyleSpec.fromJson(styleJson)
        val dark = when (spec.theme) {
            "LIGHT" -> false
            "DARK" -> true
            else -> isSystemDark(context)
        }
        val palette = paletteFor(spec.background, dark, today)

        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val unit = minOf(w, h).toFloat()
        val strokeW = maxOf(1f, unit * 0.012f)
        val corner = unit * 0.16f
        val rect = RectF(strokeW / 2f, strokeW / 2f, w - strokeW / 2f, h - strokeW / 2f)

        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, w.toFloat(), h.toFloat(),
                palette.bgTop, palette.bgBottom, Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRoundRect(rect, corner, corner, fill)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = strokeW
            color = palette.stroke
        }
        canvas.drawRoundRect(rect, corner, corner, stroke)

        drawLines(canvas, spec, palette, w, h, unit, today, total)
        return bmp
    }

    private fun drawLines(
        canvas: Canvas,
        spec: WidgetStyleSpec,
        palette: Palette,
        w: Int,
        h: Int,
        unit: Float,
        today: Int,
        total: Int,
    ) {
        val cozy = spec.density != "COMPACT"
        val todayColor = if (spec.accentByUsage) UsageLadder.color(today) else palette.today
        val lines = ArrayList<Line>(3)
        if (spec.showToday) {
            lines += Line(today.toString(), unit * (if (cozy) 0.34f else 0.30f), true, todayColor)
        }
        if (spec.showLabel) {
            lines += Line("reels today", unit * (if (cozy) 0.105f else 0.095f), false, palette.label)
        }
        if (spec.showTotal) {
            lines += Line("All time · $total", unit * (if (cozy) 0.088f else 0.080f), false, palette.total)
        }
        if (lines.isEmpty()) return

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
        val gap = unit * 0.05f
        val heights = FloatArray(lines.size)
        var blockH = 0f
        for (i in lines.indices) {
            paint.textSize = lines[i].size
            paint.typeface = if (lines[i].bold) BOLD else Typeface.DEFAULT
            val fm = paint.fontMetrics
            heights[i] = fm.descent - fm.ascent
            blockH += heights[i]
        }
        blockH += gap * (lines.size - 1)

        val cx = w / 2f
        var y = (h - blockH) / 2f
        for (i in lines.indices) {
            paint.textSize = lines[i].size
            paint.typeface = if (lines[i].bold) BOLD else Typeface.DEFAULT
            paint.color = lines[i].color
            val fm = paint.fontMetrics
            canvas.drawText(lines[i].text, cx, y - fm.ascent, paint)
            y += heights[i] + gap
        }
    }

    // ── Palette ──────────────────────────────────────────────────────────────────

    /** Shared with the block screen so both surfaces read from one palette table. */
    internal fun paletteFor(background: String, dark: Boolean, count: Int): Palette {
        val textPrimary = if (dark) 0xFFFFFFFF.toInt() else 0xFF14151A.toInt()
        val textAccent = if (dark) 0xFF44E2CD.toInt() else 0xFF12A594.toInt()
        val textMuted = if (dark) 0xFFB8C0D9.toInt() else 0xFF5A6072.toInt()
        val band = UsageLadder.color(count)

        val bg = when (background) {
            "GLASS_BRAND" -> if (dark) {
                Triple(0xFF2E2470.toInt(), 0xFF10233A.toInt(), 0x5544E2CD)
            } else {
                Triple(0xFFEDE7FF.toInt(), 0xFFDFF6F1.toInt(), 0x3344E2CD)
            }
            "SOLID" -> if (dark) {
                Triple(0xFF141B2E.toInt(), 0xFF141B2E.toInt(), 0x1FFFFFFF)
            } else {
                Triple(0xFFF3F5FC.toInt(), 0xFFF3F5FC.toInt(), 0x1A101012)
            }
            "USAGE_TINT" -> {
                val base = if (dark) 0xFF0B1326.toInt() else 0xFFFFFFFF.toInt()
                Triple(
                    blend(band, base, if (dark) 0.30f else 0.20f),
                    blend(band, base, if (dark) 0.14f else 0.34f),
                    withAlpha(band, 0x66),
                )
            }
            else -> if (dark) {
                Triple(0xFF171F33.toInt(), 0xFF0B1326.toInt(), 0x33FFFFFF)
            } else {
                Triple(0xFFFFFFFF.toInt(), 0xFFEDF0FA.toInt(), 0x22101012)
            }
        }
        return Palette(
            bgTop = bg.first,
            bgBottom = bg.second,
            stroke = bg.third,
            today = textPrimary,
            label = textAccent,
            total = textMuted,
        )
    }

    internal fun isSystemDark(context: Context): Boolean =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    private val BOLD = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    private const val MAX_PX = 1200

    private data class Line(
        val text: String,
        val size: Float,
        val bold: Boolean,
        val color: Int,
    )
}

/** One surface's colours: the widget face and the block screen read the same table. */
internal data class Palette(
    val bgTop: Int,
    val bgBottom: Int,
    val stroke: Int,
    val today: Int,
    val label: Int,
    val total: Int,
)

/** Linear RGB blend of [a] over [b] by [t] (0 = b, 1 = a); result is opaque. */
internal fun blend(a: Int, b: Int, t: Float): Int {
    fun ch(shift: Int): Int =
        (((a ushr shift) and 0xFF) * t + ((b ushr shift) and 0xFF) * (1f - t))
            .roundToInt().coerceIn(0, 255)
    return (0xFF shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
}

internal fun withAlpha(color: Int, alpha: Int): Int = (alpha shl 24) or (color and 0x00FFFFFF)

/**
 * Immutable widget appearance parsed from the JSON persisted by the Dart
 * `WidgetStyle`. Re-coerces an all-lines-off payload so the widget is never blank.
 */
data class WidgetStyleSpec(
    val background: String = "GLASS_DARK",
    val theme: String = "SYSTEM",
    val density: String = "COZY",
    val showToday: Boolean = true,
    val showLabel: Boolean = true,
    val showTotal: Boolean = true,
    val accentByUsage: Boolean = false,
) {
    companion object {
        fun fromJson(json: String?): WidgetStyleSpec {
            if (json.isNullOrEmpty()) return WidgetStyleSpec()
            return try {
                val o = JSONObject(json)
                val showToday = o.optBoolean("showToday", true)
                val showTotal = o.optBoolean("showTotal", true)
                WidgetStyleSpec(
                    background = o.optString("background", "GLASS_DARK"),
                    theme = o.optString("theme", "SYSTEM"),
                    density = o.optString("density", "COZY"),
                    showToday = showToday || !showTotal,
                    showLabel = o.optBoolean("showLabel", true),
                    showTotal = showTotal,
                    accentByUsage = o.optBoolean("accentByUsage", false),
                )
            } catch (_: Throwable) {
                WidgetStyleSpec()
            }
        }
    }
}
