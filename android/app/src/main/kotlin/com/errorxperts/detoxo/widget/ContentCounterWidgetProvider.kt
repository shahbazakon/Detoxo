package com.errorxperts.detoxo.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.RemoteViews
import com.errorxperts.detoxo.R
import com.errorxperts.detoxo.engine.ContentCounterStore
import com.errorxperts.detoxo.engine.DateKeys
import kotlin.math.roundToInt

/**
 * 2x2 home-screen widget showing today's reel count + all-time total.
 *
 * The single source of truth is [ContentCounterStore] (`detoxo_engine_prefs`),
 * so the widget stays correct even when the Flutter UI is dead — the native
 * counter calls [pushUpdate] on each counted reel (throttled) and on style
 * changes. The face is Canvas-rendered to a bitmap (see [WidgetBitmapRenderer])
 * so it honours the user's chosen glass background / theme / density. Tapping
 * launches the app via a native PendingIntent.
 */
class ContentCounterWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = ContentCounterStore(context).snapshot(dateKey())
        for (id in appWidgetIds) renderWidget(context, appWidgetManager, id, snapshot)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?,
    ) {
        // Re-render at the new size so the bitmap stays crisp after a resize.
        val snapshot = ContentCounterStore(context).snapshot(dateKey())
        renderWidget(context, appWidgetManager, appWidgetId, snapshot)
    }

    companion object {
        /**
         * Push the latest [snapshot] to every pinned instance of this widget.
         * Cheap no-op when none are pinned. Called from the counting brain and on
         * appearance changes.
         */
        fun pushUpdate(context: Context, snapshot: Map<String, Any?>) {
            val mgr = AppWidgetManager.getInstance(context) ?: return
            val component = ComponentName(context, ContentCounterWidgetProvider::class.java)
            val ids = mgr.getAppWidgetIds(component)
            if (ids.isEmpty()) return
            for (id in ids) renderWidget(context, mgr, id, snapshot)
        }

        private fun renderWidget(
            context: Context,
            mgr: AppWidgetManager,
            id: Int,
            snapshot: Map<String, Any?>,
        ) {
            val today = (snapshot["today"] as? Int) ?: 0
            val total = (snapshot["total"] as? Int) ?: 0
            val styleJson = (snapshot["widgetStyle"] as? String) ?: ""
            val (wPx, hPx) = widgetSizePx(context, mgr, id)
            val bitmap = WidgetBitmapRenderer.render(context, wPx, hPx, styleJson, today, total)
            val views = RemoteViews(context.packageName, R.layout.content_counter_widget).apply {
                setImageViewBitmap(R.id.cc_widget_image, bitmap)
                setOnClickPendingIntent(R.id.cc_widget_root, launchPendingIntent(context))
            }
            mgr.updateAppWidget(id, views)
        }

        /**
         * Pixel size for the bitmap, from the launcher-reported option dp bounds
         * (max width + min height ≈ the portrait cell). Falls back to a 2x2 default
         * before the first layout reports sizes, and clamps to bound bitmap memory.
         */
        private fun widgetSizePx(context: Context, mgr: AppWidgetManager, id: Int): Pair<Int, Int> {
            val density = context.resources.displayMetrics.density
            val opts = mgr.getAppWidgetOptions(id)
            val maxWDp = opts?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0) ?: 0
            val minHDp = opts?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0) ?: 0
            val fallback = (150 * density).roundToInt()
            val wPx = (if (maxWDp > 0) (maxWDp * density).roundToInt() else fallback).coerceIn(1, 1200)
            val hPx = (if (minHDp > 0) (minHDp * density).roundToInt() else fallback).coerceIn(1, 1200)
            return wPx to hPx
        }

        private fun launchPendingIntent(context: Context): PendingIntent {
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                } ?: Intent()
            return PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun dateKey(): String = DateKeys.today()
    }
}
