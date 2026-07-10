package com.wearlink.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
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

/// Bridges native HealthCollector to Flutter.
///
///   MethodChannel  "wearlink/health"      -> start, stop, startActive, stopActive
///   EventChannel   "wearlink/health/events" -> {type: "batch", samples: [...]}
class HealthServicesPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var collector: HealthCollector
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private var activity: Activity? = null
    /// Held while the runtime permission dialog is on screen; resolved by
    /// MainActivity.onRequestPermissionsResult -> onPermissionResult.
    private var pendingPermissionResult: Result? = null

    companion object {
        /// Request code for the BODY_SENSORS + ACTIVITY_RECOGNITION runtime request.
        const val REQ_HEALTH_PERMS = 4242
    }

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
                "requestPermissions" -> requestHealthPermissions(result)
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

    // ---- Runtime permissions (W4) ---------------------------------------

    /// Request the runtime permissions HealthCollector needs:
    ///   BODY_SENSORS         — heart rate (API 33–35; API 36+ wants READ_HEART_RATE)
    ///   ACTIVITY_RECOGNITION — steps / calories / distance
    /// Resolves [result] with true once BODY_SENSORS is granted (the hard gate
    /// for HR capture; activity types gracefully no-op without their permission).
    /// Note: background "all the time" access (BODY_SENSORS_BACKGROUND) is a
    /// separate, Settings-only grant — intentionally out of scope here.
    private fun requestHealthPermissions(result: Result) {
        val act = activity
        if (act == null) {
            result.success(hasBodySensors())
            return
        }
        val toRequest = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(act, Manifest.permission.BODY_SENSORS)
            != PackageManager.PERMISSION_GRANTED) {
            toRequest.add(Manifest.permission.BODY_SENSORS)
        }
        if (ContextCompat.checkSelfPermission(act, Manifest.permission.ACTIVITY_RECOGNITION)
            != PackageManager.PERMISSION_GRANTED) {
            toRequest.add(Manifest.permission.ACTIVITY_RECOGNITION)
        }
        if (toRequest.isEmpty()) {
            result.success(true)
            return
        }
        // Drop any overlapping request (shouldn't happen) before stalling a new one.
        pendingPermissionResult?.success(hasBodySensors())
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, toRequest.toTypedArray(), REQ_HEALTH_PERMS)
    }

    private fun hasBodySensors(): Boolean {
        val ctx = activity ?: return false
        return ContextCompat.checkSelfPermission(ctx, Manifest.permission.BODY_SENSORS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /// Called by MainActivity.onRequestPermissionsResult for our request code.
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_HEALTH_PERMS) return
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        // Re-check the actual grant state rather than trusting grantResults order.
        pending?.success(hasBodySensors())
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
