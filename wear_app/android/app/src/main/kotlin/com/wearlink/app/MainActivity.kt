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
    /// Reference to the BLE central plugin (Bridge model) so MainActivity can
    /// forward the runtime permission result (BLUETOOTH_SCAN/CONNECT) back to Flutter.
    private lateinit var bleCentralPlugin: BleCentralPlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        healthPlugin = HealthServicesPlugin()
        blePlugin = WearLinkBlePlugin()
        bleCentralPlugin = BleCentralPlugin()
        flutterEngine.plugins.add(blePlugin)
        flutterEngine.plugins.add(bleCentralPlugin)
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
        if (::bleCentralPlugin.isInitialized) {
            bleCentralPlugin.onPermissionResult(requestCode, grantResults)
        }
        // NOTE: AncsPlugin does not implement onPermissionResult or ActivityAware,
        // so ANCS runtime permissions (if any are added later) are not forwarded.
        // If ANCS ever needs runtime permissions, add ActivityAware to AncsPlugin
        // and wire onPermissionResult here.
    }
}