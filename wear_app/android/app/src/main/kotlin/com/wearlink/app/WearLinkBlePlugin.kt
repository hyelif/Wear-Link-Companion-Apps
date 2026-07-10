package com.wearlink.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID

/// Bridges native BlePeripheralService to Flutter.
///   MethodChannel  "wearlink/ble"      -> start, stop, advertiseStart, advertiseStop, notify,
///                                         requestPermissions
///   EventChannel   "wearlink/ble/events" -> {type: "conn"|"frame", ...}
class WearLinkBlePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var service: BlePeripheralService
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private var activity: Activity? = null
    /// Held while the runtime BLE permission dialog is on screen; resolved by
    /// MainActivity.onRequestPermissionsResult -> onPermissionResult.
    private var pendingPermissionResult: Result? = null

    companion object {
        /// Request code for the BLUETOOTH_SCAN/CONNECT/ADVERTISE runtime request.
        const val REQ_BLE_PERMS = 4243

        /// Runtime (dangerous) BLE permissions required on API 31+ (Wear OS 3+ /
        /// Android 12+) to advertise + run a GATT server. Below API 31 these are
        /// install-time grants and the request is a no-op (we still ask; the
        /// system simply returns granted without prompting).
        private val BLE_RUNTIME_PERMS = arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )
    }

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
                "getDeviceInfo" -> result.success(service.deviceInfoSnapshot())
                "setDeviceInfo" -> {
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    service.setDeviceInfoResponse(data)
                    result.success(true)
                }
                "requestPermissions" -> requestBlePermissions(result)
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

    // ---- Runtime permissions (Wear OS 3+ / API 31+) ---------------------

    /// Request BLUETOOTH_SCAN + BLUETOOTH_CONNECT + BLUETOOTH_ADVERTISE at runtime.
    /// On API 31+ these are dangerous permissions gating the GATT server +
    /// advertiser; without the grant, startAdvertising() silently fails
    /// (AdvertiseCallback.onStartFailure) and openGattServer cannot exchange
    /// data — the watch is invisible to the iPhone. MUST be awaited from Dart
    /// before `start` / `advertiseStart`. Resolves with true when all three are
    /// granted (the hard gate for the peripheral role).
    private fun requestBlePermissions(result: Result) {
        // Below API 31 the BLE perms are install-time grants — nothing to request.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            // No activity bound yet — fall back to the current grant state.
            result.success(hasBlePerms())
            return
        }
        val toRequest = BLE_RUNTIME_PERMS.filter {
            ContextCompat.checkSelfPermission(act, it) != PackageManager.PERMISSION_GRANTED
        }
        if (toRequest.isEmpty()) {
            result.success(true)
            return
        }
        // Drop any overlapping request (shouldn't happen) before stalling a new one.
        pendingPermissionResult?.success(hasBlePerms())
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, toRequest.toTypedArray(), REQ_BLE_PERMS)
    }

    private fun hasBlePerms(): Boolean {
        val ctx = activity ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return BLE_RUNTIME_PERMS.all {
            ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    /// Called by MainActivity.onRequestPermissionsResult for our request code.
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_BLE_PERMS) return
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        // Re-check the actual grant state rather than trusting grantResults order.
        pending?.success(hasBlePerms())
    }

    // ---- ActivityAware ---------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
        pendingPermissionResult?.success(false)
        pendingPermissionResult = null
    }
}