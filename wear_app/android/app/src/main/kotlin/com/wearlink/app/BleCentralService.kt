package com.wearlink.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

/// BLE central (GATT client) for the Bridge model.
///
/// The watch acts as a GATT client, scanning for and connecting to the iPhone
/// (which is now the GATT server/peripheral). This is the inverse of the
/// original architecture where the watch was the GATT server.
///
/// Duty-cycled scan: 2s on / 8s off to save battery.
/// No foreground service needed — runs from application context.
///
/// Static callback holders (sOnConn, sOnFrame, sOnMtu, sOnError) follow the
/// same pattern as BlePeripheralService so the plugin can wire callbacks
/// before the service is started.
class BleCentralService(private val context: Context) {

    companion object {
        private const val TAG = "WearLink/Central"
        /// How long each scan window lasts before pausing.
        private const val SCAN_DURATION_MS = 2_000L
        /// How long to pause between scan windows.
        private const val SCAN_PAUSE_MS = 8_000L

        // Static callback holders so the plugin can wire callbacks before
        // the service is started (same pattern as BlePeripheralService).
        @Volatile var sOnConn: ((ConnState) -> Unit)? = null
        @Volatile var sOnFrame: ((UUID, ByteArray) -> Unit)? = null
        @Volatile var sOnMtu: ((Int) -> Unit)? = null
        @Volatile var sOnError: ((String) -> Unit)? = null
    }

    enum class ConnState { DISCONNECTED, CONNECTING, CONNECTED }

    var onConnState: ((ConnState) -> Unit)? = null
    var onFrame: ((UUID, ByteArray) -> Unit)? = null
    var onMtuChanged: ((Int) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private val handler = Handler(Looper.getMainLooper())
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var scanning = false
    @Volatile private var connState = ConnState.DISCONNECTED
    @Volatile private var negotiatedMtu = 23

    /// Track which characteristics we have successfully subscribed to via CCCD.
    private val subscribedChars = mutableSetOf<UUID>()

    // ---- Lifecycle --------------------------------------------------------

    /// Start scanning for the iPhone. Checks BLE permissions (API 31+),
    /// wires static callbacks into instance fields, then begins the
    /// duty-cycled scan loop.
    fun start() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED ||
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "Missing BLUETOOTH_SCAN or BLUETOOTH_CONNECT permission for Android 12+")
                handler.post { onError?.invoke("Missing BLUETOOTH_SCAN or BLUETOOTH_CONNECT permission") }
                return
            }
        }
        val adapter = BluetoothAdapter.getDefaultAdapter()
        bluetoothAdapter = adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth not available or not enabled")
            handler.post { onError?.invoke("Bluetooth not available or not enabled") }
            return
        }
        // Wire static callbacks (set by the plugin before start) into instance
        // fields so GATT callbacks reach Flutter.
        onConnState = sOnConn
        onFrame = sOnFrame
        onMtuChanged = sOnMtu
        onError = sOnError
        Log.i(TAG, "start: beginning duty-cycled scan")
        startDutyCycledScan()
    }

    /// Stop scanning and disconnect from the iPhone. Clears all state.
    fun stop() {
        Log.i(TAG, "stop: tearing down central connection")
        stopDutyCycledScan()
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        connState = ConnState.DISCONNECTED
        subscribedChars.clear()
        handler.post { onConnState?.invoke(ConnState.DISCONNECTED) }
    }

    /// Disconnect from the iPhone without stopping the scan cycle.
    /// The duty-cycled scan will resume automatically on disconnect.
    fun disconnect() {
        Log.i(TAG, "disconnect: disconnecting from iPhone")
        gatt?.disconnect()
    }

    // ---- Duty-cycled scan -------------------------------------------------
    //
    // Scan for SCAN_DURATION_MS (2s), then pause for SCAN_PAUSE_MS (8s) to
    // save battery. The cycle repeats until a device is found or stop() is
    // called. When connected, the cycle is paused.

    private val scanRunnable = object : Runnable {
        override fun run() {
            if (connState == ConnState.CONNECTED) {
                Log.d(TAG, "scan cycle: already connected — skipping scan")
                return
            }
            startScan()
            // Stop scanning after the duration window, then schedule the next
            // scan after the pause interval.
            handler.postDelayed({
                stopScan()
                handler.postDelayed(this, SCAN_PAUSE_MS)
            }, SCAN_DURATION_MS)
        }
    }

    private fun startDutyCycledScan() {
        handler.removeCallbacks(scanRunnable)
        scanRunnable.run()
    }

    private fun stopDutyCycledScan() {
        handler.removeCallbacks(scanRunnable)
        stopScan()
    }

    // ---- Scan for iPhone --------------------------------------------------

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            Log.i(TAG, "Found WearLink device: ${device.name ?: "Unknown"} [${device.address}]")
            // Stop scanning immediately and cancel the duty cycle — we found
            // the iPhone and will attempt to connect.
            stopScan()
            handler.removeCallbacks(scanRunnable)
            connect(device)
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: errorCode=$errorCode")
            // The duty-cycled scan will retry on the next cycle.
        }
    }

    private fun startScan() {
        if (scanning || connState == ConnState.CONNECTED) return
        val adapter = bluetoothAdapter ?: return
        val scanner = adapter.bluetoothLeScanner ?: return
        scanning = true
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .build()
        // Filter by the WearLink service UUID so we only find iPhones
        // advertising the WearLink GATT service.
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(Uuids.service))
            .build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        Log.d(TAG, "Scanning for WearLink devices...")
    }

    private fun stopScan() {
        if (!scanning) return
        val adapter = bluetoothAdapter ?: return
        val scanner = adapter.bluetoothLeScanner
        if (scanner != null) {
            try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
        }
        scanning = false
    }

    // ---- Connect to iPhone via GATT --------------------------------------

    private fun connect(device: BluetoothDevice) {
        Log.i(TAG, "Connecting to ${device.address}...")
        setConn(ConnState.CONNECTING)
        // autoConnect=false: we initiate the connection immediately.
        gatt = device.connectGatt(context, false, gattCallback)
    }

    // ---- Write to characteristic -----------------------------------------

    /// Write data to a characteristic on the iPhone's GATT server.
    /// Returns true if the write was initiated successfully.
    fun write(uuid: UUID, data: ByteArray): Boolean {
        val gatt = gatt ?: return false
        val svc = gatt.getService(Uuids.service) ?: return false
        val c = svc.getCharacteristic(uuid) ?: return false
        c.value = data
        return try {
            gatt.writeCharacteristic(c)
        } catch (e: Exception) {
            Log.e(TAG, "write failed for $uuid", e)
            false
        }
    }

    // ---- Request MTU ------------------------------------------------------

    /// Request a larger ATT MTU for better throughput.
    /// Returns true if the request was sent successfully.
    fun requestMtu(mtu: Int): Boolean {
        val gatt = gatt ?: return false
        return try {
            gatt.requestMtu(mtu)
        } catch (e: Exception) {
            Log.e(TAG, "requestMtu failed", e)
            false
        }
    }

    // ---- GATT callbacks ---------------------------------------------------

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "GATT CONNECTED: ${gatt.device.address} (status=$status)")
                    setConn(ConnState.CONNECTED)
                    // Discover services to find the WearLink service and its
                    // characteristics.
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "GATT DISCONNECTED (status=$status)")
                    gatt.close()
                    subscribedChars.clear()
                    setConn(ConnState.DISCONNECTED)
                    // Re-enter the duty-cycled scan after a short delay so the
                    // previous connection fully tears down.
                    handler.postDelayed({ startDutyCycledScan() }, 3000)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed: status=$status")
                handler.post { onError?.invoke("Service discovery failed: status=$status") }
                return
            }
            val svc = gatt.getService(Uuids.service)
            if (svc == null) {
                Log.w(TAG, "WearLink service not found on iPhone — unexpected")
                handler.post { onError?.invoke("WearLink service not found on iPhone") }
                return
            }
            Log.i(TAG, "WearLink service discovered — subscribing to notification characteristics")

            // Subscribe to characteristics the iPhone notifies on:
            //   FE10 deviceInfo, FE20 healthStream, FE30 callEvent,
            //   FE40 notification, FE50 musicNowPlaying, FE60 linkControl
            val notifyUuids = listOf(
                Uuids.deviceInfo,
                Uuids.healthStream,
                Uuids.callEvent,
                Uuids.notification,
                Uuids.musicNowPlaying,
                Uuids.linkControl
            )
            for (uuid in notifyUuids) {
                val c = svc.getCharacteristic(uuid)
                if (c != null) {
                    subscribeToCharacteristic(gatt, c)
                } else {
                    Log.w(TAG, "Characteristic $uuid not found on iPhone")
                }
            }

            // Request larger MTU for better throughput (247 is the WearLink
            // standard MTU). The result arrives in onMtuChanged.
            gatt.requestMtu(247)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val uuid = characteristic.uuid
            val data = characteristic.value ?: return
            Log.d(TAG, "Notification from $uuid: ${data.size} bytes")
            // Forward the raw frame to Dart via the callback. The Dart codec
            // handles reassembly and protobuf decode.
            handler.post { onFrame?.invoke(uuid, data) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "Write failed for ${characteristic.uuid}: status=$status")
                handler.post { onError?.invoke("Write failed for ${characteristic.uuid}: status=$status") }
            } else {
                Log.d(TAG, "Write succeeded for ${characteristic.uuid}")
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val charUuid = descriptor.characteristic?.uuid
            if (charUuid != null) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.i(TAG, "CCCD write succeeded for $charUuid — subscribed")
                    subscribedChars.add(charUuid)
                } else {
                    Log.w(TAG, "CCCD write failed for $charUuid: status=$status")
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                negotiatedMtu = mtu
                Log.i(TAG, "MTU negotiated: $mtu")
                handler.post { onMtuChanged?.invoke(mtu) }
            } else {
                Log.w(TAG, "MTU request failed: status=$status")
            }
        }
    }

    // ---- Subscribe to characteristic notifications ------------------------

    /// Enable notifications on a characteristic by writing to its CCCD
    /// descriptor. Idempotent: skips if already subscribed.
    private fun subscribeToCharacteristic(gatt: BluetoothGatt, c: BluetoothGattCharacteristic) {
        val uuid = c.uuid
        if (uuid in subscribedChars) {
            Log.d(TAG, "subscribeToCharacteristic: $uuid already subscribed — skip")
            return
        }
        val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
        val cccd = c.getDescriptor(cccdUuid)
        if (cccd != null) {
            gatt.setCharacteristicNotification(c, true)
            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(cccd)
            Log.d(TAG, "Subscribing to $uuid")
        } else {
            Log.w(TAG, "No CCCD descriptor found for $uuid — cannot subscribe")
        }
    }

    // ---- State management ------------------------------------------------

    private fun setConn(s: ConnState) {
        connState = s
        handler.post { onConnState?.invoke(s) }
    }
}
