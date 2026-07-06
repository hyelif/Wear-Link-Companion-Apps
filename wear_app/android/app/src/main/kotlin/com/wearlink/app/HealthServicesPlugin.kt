package com.wearlink.app

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/// Bridges native HealthCollector to Flutter.
///
///   MethodChannel  "wearlink/health"      -> start, stop, startActive, stopActive
///   EventChannel   "wearlink/health/events" -> {type: "batch", samples: [...]}
class HealthServicesPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var collector: HealthCollector
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx: Context = binding.applicationContext
        collector = HealthCollector(ctx)
        collector.onBatch = { samples ->
            mainHandler.post {
                val list = samples.map { s ->
                    mapOf(
                        "type" to s.type,
                        "value" to s.value,
                        "timestampMs" to s.timestampMs
                    )
                }
                eventSink?.success(mapOf("type" to "batch", "samples" to list))
            }
        }
        methodChannel = MethodChannel(binding.binaryMessenger, "wearlink/health").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "wearlink/health/events").also {
            it.setStreamHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "start" -> { collector.start(); result.success(true) }
                "stop" -> { collector.stop(); result.success(true) }
                "startActive" -> { collector.startActive(); result.success(true) }
                "stopActive" -> { collector.stopActive(); result.success(true) }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e("HealthServicesPlugin", "method ${call.method} failed", t)
            result.error("health_error", t.message, null)
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
        try { collector.stop() } catch (_: Throwable) {}
    }
}
