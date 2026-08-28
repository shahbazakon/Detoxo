package com.errorxperts.detoxo.engine

import android.os.Handler
import android.os.Looper

/**
 * In-process bridge from the AccessibilityService to the Flutter EventChannel.
 *
 * The service posts events here; when the Flutter engine is alive its
 * EventChannel stream handler registers a [sink] and receives them (always on
 * the main thread). When the UI is dead, events are simply dropped — the block
 * hot-path does not depend on Dart.
 */
object ServiceEventBus {

    fun interface Sink {
        fun emit(event: Map<String, Any?>)
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var sink: Sink? = null

    /**
     * Sticky last serviceStatus payload, recorded even with no listener. A cold
     * start races the service rebind: onServiceConnected's `running=true` fires
     * before Dart attaches the EventChannel and would otherwise be lost, leaving
     * the dashboard on "Protection off" for the whole session.
     */
    @Volatile
    private var lastServiceStatus: Map<String, Any?>? = null

    fun post(type: String, data: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>(data).apply { put("type", type) }
        if (type == "serviceStatus") lastServiceStatus = payload
        val sink = this.sink ?: return
        mainHandler.post { sink.emit(payload) }
    }

    /** Replays the sticky serviceStatus to the current sink (no-op without one). */
    fun replayLastStatus() {
        val payload = lastServiceStatus ?: return
        val sink = this.sink ?: return
        mainHandler.post { sink.emit(payload) }
    }
}
