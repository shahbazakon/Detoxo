package com.errorxperts.detoxo.channels

import com.errorxperts.detoxo.engine.ServiceEventBus
import io.flutter.plugin.common.EventChannel

/**
 * Bridges [ServiceEventBus] to the Flutter EventChannel. While Dart is
 * listening, native engine events (status, detections, blocks) flow through.
 */
class DetoxoEventStream : EventChannel.StreamHandler {

    private var mySink: ServiceEventBus.Sink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        mySink = if (events == null) null else ServiceEventBus.Sink { events.success(it) }
        ServiceEventBus.sink = mySink
        // Catch a late subscriber up: onServiceConnected's serviceStatus fires
        // before Dart attaches on a cold start and would otherwise be dropped.
        ServiceEventBus.replayLastStatus()
    }

    override fun onCancel(arguments: Any?) {
        // Engine recreation can run the new engine's onListen before the old
        // engine's onCancel — only clear the sink this instance installed.
        if (ServiceEventBus.sink === mySink) ServiceEventBus.sink = null
        mySink = null
    }
}
