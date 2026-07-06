package com.wearlink.app

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/// Bridges native AncsClient to Flutter.
///
///   MethodChannel  "wearlink/ancs"       -> start, stop
///   EventChannel   "wearlink/ancs/events" -> {type: "notification", appId, title, message, timestampMs}
class AncsPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var client: AncsClient
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx: Context = binding.applicationContext
        client = AncsClient(ctx)
        client.onNotification = { n ->
            mainHandler.post {
                eventSink?.success(
                    mapOf(
                        "type" to "notification",
                        "appName" to n.appName,
                        "title" to n.title,
                        "body" to n.body,
                        "notifId" to n.notifId,
                        "timestampMs" to n.timestampMs
                    )
                )
            }
        }
        methodChannel = MethodChannel(binding.binaryMessenger, "wearlink/ancs").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "wearlink/ancs/events").also {
            it.setStreamHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "start" -> { client.start(); result.success(true) }
                "stop" -> { client.stop(); result.success(true) }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e("AncsPlugin", "method ${call.method} failed", t)
            result.error("ancs_error", t.message, null)
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        try { client.stop() } catch (_: Throwable) {}
    }
}
