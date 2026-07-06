package com.wearlink.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.wearlink.app.AncsPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(WearLinkBlePlugin())
        flutterEngine.plugins.add(HealthServicesPlugin())
        flutterEngine.plugins.add(AncsPlugin())
    }
}