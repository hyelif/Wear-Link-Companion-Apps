package com.wearlink.app

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID

/// Bridges native BlePeripheralService to Flutter.
///   MethodChannel  "wearlink/ble"      -> start, stop, advertiseStart, advertiseStop, notify
///   EventChannel   "wearlink/ble/events" -> {type: "conn"|"frame", ...}
class WearLinkBlePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var service: BlePeripheralService
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx: Context = binding.applicationContext
        service = BlePeripheralService(ctx)
        service.onConnState = { s ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "conn", "state" to s.name))
            }
        }
        service.onFrame = { uuid, frame ->
            mainHandler.post {
                eventSink?.success(
                    mapOf("type" to "frame", "uuid" to uuid.toString(), "data" to frame)
                )
            }
        }
        methodChannel = MethodChannel(binding.binaryMessenger, "wearlink/ble").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "wearlink/ble/events").also {
            it.setStreamHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "start" -> { service.start(); result.success(true) }
                "stop" -> { service.stop(); result.success(true) }
                "advertiseStart" -> { service.startAdvertising(); result.success(true) }
                "advertiseStop" -> { service.stopAdvertising(); result.success(true) }
                "notify" -> {
                    val uuid = UUID.fromString(call.argument<String>("uuid"))
                    @Suppress("UNCHECKED_CAST")
                    val data = (call.argument<ByteArray>("data") ?: ByteArray(0))
                    result.success(service.notify(uuid, data))
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e("WearLinkBlePlugin", "method ${call.method} failed", t)
            result.error("ble_error", t.message, null)
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
        try { service.stop() } catch (_: Throwable) {}
    }
}