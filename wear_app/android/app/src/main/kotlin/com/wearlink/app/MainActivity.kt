package com.wearlink.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.wearlink.app.AncsPlugin

class MainActivity : FlutterActivity() {
    /// Reference to the health plugin so MainActivity can forward the runtime
    /// permission result (BODY_SENSORS + ACTIVITY_RECOGNITION) back to Flutter.
    private lateinit var healthPlugin: HealthServicesPlugin
    /// Reference to the BLE plugin so MainActivity can forward the runtime
    /// permission result (BLUETOOTH_SCAN/CONNECT/ADVERTISE) back to Flutter.
    private lateinit var blePlugin: WearLinkBlePlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        healthPlugin = HealthServicesPlugin()
        blePlugin = WearLinkBlePlugin()
        flutterEngine.plugins.add(blePlugin)
        flutterEngine.plugins.add(healthPlugin)
        flutterEngine.plugins.add(AncsPlugin())
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (::healthPlugin.isInitialized) {
            healthPlugin.onPermissionResult(requestCode, grantResults)
        }
        if (::blePlugin.isInitialized) {
            blePlugin.onPermissionResult(requestCode, grantResults)
        }
    }
}