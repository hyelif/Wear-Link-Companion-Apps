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

/// Bridges native BleCentralService to Flutter.
///
///   MethodChannel  "wearlink/ble_central"       -> startScan, stopScan, disconnect, write, requestMtu
///   EventChannel   "wearlink/ble_central/events" -> {type: "conn"|"frame"|"mtu"|"error", ...}
///
/// Modeled after AncsPlugin (direct construction, no FGS indirection) with
/// the static-callback wiring pattern from WearLinkBlePlugin.
class BleCentralPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var central: BleCentralService
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx: Context = binding.applicationContext
        central = BleCentralService(ctx)

        // Wire static callbacks so GATT events reach Flutter. Posting to the
        // main thread keeps the EventChannel thread-safe (GATT callbacks arrive
        // on binder/GATT threads).
        BleCentralService.sOnConn = { s ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "conn", "state" to s.name))
            }
        }
        BleCentralService.sOnFrame = { uuid, frame ->
            mainHandler.post {
                eventSink?.success(
                    mapOf("type" to "frame", "uuid" to uuid.toString(), "data" to frame)
                )
            }
        }
        BleCentralService.sOnMtu = { mtu ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "mtu", "mtu" to mtu))
            }
        }
        BleCentralService.sOnError = { msg ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "error", "msg" to msg))
            }
        }

        // Push the fresh callbacks into the instance so events reach Flutter
        // even if the service was already started before the plugin attached.
        central.onConnState = BleCentralService.sOnConn
        central.onFrame = BleCentralService.sOnFrame
        central.onMtuChanged = BleCentralService.sOnMtu
        central.onError = BleCentralService.sOnError

        methodChannel = MethodChannel(binding.binaryMessenger, "wearlink/ble_central").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "wearlink/ble_central/events").also {
            it.setStreamHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "startScan" -> {
                    central.start()
                    result.success(true)
                }
                "stopScan" -> {
                    central.stop()
                    result.success(true)
                }
                "disconnect" -> {
                    central.disconnect()
                    result.success(true)
                }
                "write" -> {
                    val uuid = UUID.fromString(call.argument<String>("uuid"))
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    result.success(central.write(uuid, data))
                }
                "requestMtu" -> {
                    val mtu = call.argument<Int>("mtu") ?: 247
                    result.success(central.requestMtu(mtu))
                }
                "createBond" -> {
                    result.success(central.createBond())
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e("BleCentralPlugin", "method ${call.method} failed", t)
            result.error("ble_central_error", t.message, null)
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
        // Clear static callback holders so a re-attach does not copy stale
        // lambdas capturing a dead eventSink.
        BleCentralService.sOnConn = null
        BleCentralService.sOnFrame = null
        BleCentralService.sOnMtu = null
        BleCentralService.sOnError = null
        try { central.stop() } catch (_: Throwable) {}
    }
}
