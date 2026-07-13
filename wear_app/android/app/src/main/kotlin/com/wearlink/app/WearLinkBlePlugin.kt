package com.wearlink.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
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

/// Bridges native BlePeripheralService (now a real foreground Service) to
/// Flutter.
///   MethodChannel  "wearlink/ble"      -> start, stop, advertiseStart, advertiseStop,
///                                         notify, getDeviceInfo, setDeviceInfo,
///                                         requestPermissions
///   EventChannel   "wearlink/ble/events" -> {type: "conn"|"frame", ...}
///
/// The plugin no longer constructs BlePeripheralService directly. Instead it
/// wires static callbacks on the companion (BEFORE the service is launched)
/// and starts/stops the Service via the system. The running instance is
/// reached through BlePeripheralService.instance.
class WearLinkBlePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var ctx: Context
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
        /// POST_NOTIFICATIONS is included on API 33+ so the foreground-service
        /// notification is visible — without it some OEM/Wear-OS builds kill the
        /// FGS when the screen dims, defeating the whole "survive screen-off" goal.
        private val BLE_RUNTIME_PERMS = arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ctx = binding.applicationContext
        // Wire static callbacks on the companion BEFORE the service is launched.
        // onCreate() copies these into the instance fields, so events fired after
        // creation reach Flutter. Posting to the main thread keeps the EventChannel
        // thread-safe (GATT callbacks arrive on binder/GATT threads).
        BlePeripheralService.sOnConn = { s ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "conn", "state" to s.name))
            }
        }
        BlePeripheralService.sOnFrame = { uuid, frame ->
            mainHandler.post {
                eventSink?.success(
                    mapOf("type" to "frame", "uuid" to uuid.toString(), "data" to frame)
                )
            }
        }
        // Surface the negotiated ATT MTU so Dart can size outbound notify chunks
        // to the real MTU instead of a hardcoded 240 (which silently breaks notify
        // when iOS negotiates a smaller MTU or the default 23). Also surface
        // start/operation failures so Dart learns why advertising/connect died.
        BlePeripheralService.sOnMtu = { mtu ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "mtu", "mtu" to mtu))
            }
        }
        BlePeripheralService.sOnError = { msg ->
            mainHandler.post {
                eventSink?.success(mapOf("type" to "error", "msg" to msg))
            }
        }
        // If the service is ALREADY running (activity recreated by Wear OS while
        // the FGS kept running), push the fresh callbacks into the live instance
        // — onCreate only copies them once at first creation, so without this a
        // re-attached engine would never receive conn/frame events (the instance
        // would still hold the previous engine's dead-sink lambdas).
        BlePeripheralService.instance?.let { inst ->
            inst.onConnState = BlePeripheralService.sOnConn
            inst.onFrame = BlePeripheralService.sOnFrame
            inst.onMtuChanged = BlePeripheralService.sOnMtu
            inst.onError = BlePeripheralService.sOnError
            Log.i("WearLink/Ble", "onAttachedToEngine: re-attached to running FGS instance")
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
                "start" -> {
                    // Launch the foreground service (legal: activity is in the
                    // foreground when this method channel call fires).
                    BlePeripheralService.launch(ctx)
                    result.success(true)
                }
                "stop" -> {
                    ctx.stopService(Intent(ctx, BlePeripheralService::class.java))
                    result.success(true)
                }
                "advertiseStart" -> {
                    BlePeripheralService.instance?.startAdvertising()
                    result.success(true)
                }
                "advertiseStop" -> {
                    BlePeripheralService.instance?.stopAdvertising()
                    result.success(true)
                }
                "notify" -> {
                    val inst = BlePeripheralService.instance
                    val uuid = UUID.fromString(call.argument<String>("uuid"))
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    result.success(inst?.notify(uuid, data) ?: false)
                }
                "getDeviceInfo" ->
                    result.success(BlePeripheralService.instance?.deviceInfoSnapshot() ?: emptyMap<String, Any>())
                "setDeviceInfo" -> {
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    BlePeripheralService.instance?.setDeviceInfoResponse(data)
                    result.success(true)
                }
                "requestPermissions" -> requestBlePermissions(result)
                "requestBatteryExemption" -> requestBatteryExemption(result)
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
        // CRITICAL: do NOT stop the foreground service here. On Wear OS the
        // activity is destroyed (engine detaches) within seconds of the screen
        // dimming — if we stopService() here, the FGS and its BLE advertiser die
        // exactly when we need them most (screen off), and iOS connect() hangs.
        // The FGS must outlive the Flutter engine. It is stopped ONLY by an
        // explicit "stop" method call (user disconnect) or app uninstall.
        Log.i("WearLink/Ble", "onDetachedFromEngine: keeping FGS alive (advertiser survives)")
        // Drop the static callback holders so a START_STICKY system-restart of the
        // service (before a new engine re-attaches) does not copy stale lambdas
        // that capture this dead plugin's eventSink. A fresh attach re-sets them
        // and pushes them into the live instance (see onAttachedToEngine).
        BlePeripheralService.sOnConn = null
        BlePeripheralService.sOnFrame = null
        BlePeripheralService.sOnMtu = null
        BlePeripheralService.sOnError = null
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
        val toRequest = BLE_RUNTIME_PERMS.toMutableList()
        // POST_NOTIFICATIONS (API 33+) so the FGS notification shows and the
        // service is not killed on screen-dim. Not a hard BLE gate, so it is NOT
        // checked in hasBlePerms — but requested here so it gets granted.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            toRequest.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val need = toRequest.filter {
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
        Log.i("WearLink/Ble", "BLE permission result: granted=$granted " +
            "(grantResults=${grantResults.joinToString()})")
        pending?.success(granted)
    }

    /// Request exemption from battery optimization so the system does not kill
    /// the FGS when the app goes to background. On Wear OS the system is very
    /// aggressive about stopping foreground services — without this exemption
    /// the service is killed within seconds of screen-off, the GATT server
    /// disappears, and the iPhone can never complete a connection.
    /// This opens the system Settings page for the user to toggle "Don't
    /// optimize" on. Returns true if already exempted, false if the user
    /// needs to grant it manually.
    private fun requestBatteryExemption(result: Result) {
        val act = activity ?: run { result.success(false); return }
        val pm = act.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
        if (pm == null) { result.success(false); return }
        if (pm.isIgnoringBatteryOptimizations(act.packageName)) {
            Log.i("WearLink/Ble", "requestBatteryExemption: already exempted")
            result.success(true)
            return
        }
        // Open the system battery optimization settings for our app.
        val intent = Intent(
            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            android.net.Uri.parse("package:${act.packageName}")
        )
        // FLAG_ACTIVITY_NEW_TASK is needed because we may not be in an activity
        // context when this is called from the plugin.
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        act.startActivity(intent)
        Log.i("WearLink/Ble", "requestBatteryExemption: opened system settings — user must toggle 'Don't optimize'")
        // We can't wait for the result, so return false to indicate the user
        // needs to manually grant it.
        result.success(false)
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