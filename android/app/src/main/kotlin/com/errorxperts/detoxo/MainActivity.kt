package com.errorxperts.detoxo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import androidx.core.content.ContextCompat
import com.errorxperts.detoxo.channels.CommandHandler
import com.errorxperts.detoxo.channels.DetoxoEventStream
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity (required by local_auth) that wires the command
 * MethodChannel and the engine EventChannel to the Flutter engine, and tracks
 * the last screen-off for the PIN lock's "when screen turns off" auto-lock.
 */
class MainActivity : FlutterFragmentActivity() {

    private var commandHandler: CommandHandler? = null

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            lastScreenOffMillis = System.currentTimeMillis()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // ponytail: wall-clock stamp; a user clock change skews one comparison.
        // ponytail: API-34 broadcast deferral for cached processes can deliver a
        // screen-off after the resume query — one missed relock, self-heals.
        ContextCompat.registerReceiver(
            this,
            screenOffReceiver,
            IntentFilter(Intent.ACTION_SCREEN_OFF),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val handler = CommandHandler(applicationContext, this)
        commandHandler = handler
        MethodChannel(messenger, COMMANDS_CHANNEL).setMethodCallHandler(handler)
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(DetoxoEventStream())
    }

    override fun onDestroy() {
        unregisterReceiver(screenOffReceiver)
        commandHandler?.attachActivity(null)
        super.onDestroy()
    }

    companion object {
        private const val COMMANDS_CHANNEL = "com.errorxperts.detoxo/commands"
        private const val EVENTS_CHANNEL = "com.errorxperts.detoxo/events"

        /**
         * Wall-clock millis of the last ACTION_SCREEN_OFF this process (0 =
         * never). In-memory only: process death cold-starts through the splash
         * PIN gate anyway, so nothing needs persisting.
         */
        @Volatile
        var lastScreenOffMillis = 0L
    }
}
