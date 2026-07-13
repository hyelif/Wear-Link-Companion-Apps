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

/// Bridges native BleCentralService to Flutter.
///
///   MethodChannel  "wearlink/ble_central"       -> startScan, stopScan, disconnect, write, requestMtu, requestPermissions
///   EventChannel   "wearlink/ble_central/events" -> {type: "conn"|"frame"|"mtu"|"error", ...}
///
/// Modeled after AncsPlugin (direct construction, no FGS indirection) with
/// the static-callback wiring pattern from WearLinkBlePlugin.
class BleCentralPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var central: BleCentralService
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private var activity: Activity? = null
    /// Held while the runtime BLE permission dialog is on screen; resolved by
    /// MainActivity.onRequestPermissionsResult -> onPermissionResult.
    private var pendingPermissionResult: Result? = null

    companion object {
        /// Request code for the BLUETOOTH_SCAN/CONNECT runtime request.
        const val REQ_BLE_PERMS = 4244

        /// Runtime (dangerous) BLE permissions required on API 31+ (Wear OS 3+ /
        /// Android 12+) to scan + connect as a GATT client. Below API 31 these are
        /// install-time grants and the request is a no-op.
        private val BLE_RUNTIME_PERMS = arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT
        )
    }

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
                "requestPermissions" -> requestBlePermissions(result)
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e("BleCentralPlugin", "method ${call.method} failed", t)
            result.error("ble_central_error", t.message, null)
        }
    }

    // ---- Runtime permissions (Wear OS 3+ / API 31+) ---------------------

    /// Request BLUETOOTH_SCAN + BLUETOOTH_CONNECT at runtime.
    /// On API 31+ these are dangerous permissions gating the BLE central scanner;
    /// without the grant, startScan() silently fails and the watch cannot find
    /// the iPhone. MUST be awaited from Dart before `startScan`.
    /// Resolves with true when all required permissions are granted.
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
        val need = BLE_RUNTIME_PERMS.filter {
            ContextCompat.checkSelfPermission(act, it) != PackageManager.PERMISSION_GRANTED
        }
        if (need.isEmpty()) {
            result.success(true)
            return
        }
        // Drop any overlapping request (shouldn't happen) before stalling a new one.
        pendingPermissionResult?.success(hasBlePerms())
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, need.toTypedArray(), REQ_BLE_PERMS)
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
        val granted = hasBlePerms()
        Log.i("BleCentralPlugin", "BLE permission result: granted=$granted " +
            "(grantResults=${grantResults.joinToString()})")
        pending?.success(granted)
    }

    // ---- ActivityAware --------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener { requestCode, permissions, grantResults ->
            onPermissionResult(requestCode, IntArray(grantResults.size) { grantResults[it] })
            false
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    // ---- EventChannel ---------------------------------------------------

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
