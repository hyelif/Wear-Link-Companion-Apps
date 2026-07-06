package com.wearlink.app

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
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/// ANCS (Apple Notification Center Service) client.
///
/// Watch acts as BLE central to connect to iPhone's ANCS service.
/// This lets us read ALL iOS notifications (any app) directly from the system,
/// same approach used by OrienLabs Bridge.
///
/// Requires dual BLE roles: peripheral (WearLink GATT server) + central (ANCS).
/// Galaxy Watch 7 supports this (BLE 5.0).
///
/// ANCS Service UUID: 7905F431-B5CE-4E99-A40F-4B1E122D00D0
class AncsClient(private val context: Context) {

    data class AncsNotification(
        val notifId: String,
        val appName: String,
        val title: String,
        val body: String,
        val timestampMs: Long
    )

    var onNotification: ((AncsNotification) -> Unit)? = null

    private val handler = Handler(Looper.getMainLooper())
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var scanning = false

    // ANCS UUIDs
    companion object {
        val ANCS_SERVICE = UUID.fromString("7905F431-B5CE-4E99-A40F-4B1E122D00D0")
        val NOTIFICATION_SOURCE = UUID.fromString("9FBF120D-6301-42D9-8C58-25E699A21DBD")
        val CONTROL_POINT = UUID.fromString("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9")
        val DATA_SOURCE = UUID.fromString("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB")
        val CCCD = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
        private const val TAG = "AncsClient"
    }

    // ---- Lifecycle --------------------------------------------------------

    fun start() {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        bluetoothAdapter = adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth not available or not enabled")
            return
        }
        startScan()
    }

    fun stop() {
        stopScan()
        gatt?.close()
        gatt = null
    }

    // ---- Scan for iPhone --------------------------------------------------

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            if (device.name?.contains("iPhone") == true || device.name?.contains("iOS") == true) {
                Log.i(TAG, "Found iOS device: ${device.name} [${device.address}]")
                stopScan()
                connect(device)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
            // Retry after delay
            handler.postDelayed({ startScan() }, 10000)
        }
    }

    private fun startScan() {
        if (scanning) return
        val adapter = bluetoothAdapter ?: return
        val scanner = adapter.bluetoothLeScanner ?: return
        scanning = true
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .build()
        scanner.startScan(null, settings, scanCallback)
        Log.d(TAG, "Scanning for iPhone...")
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
        gatt = device.connectGatt(context, false, gattCallback)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to ${gatt.device.address}")
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected")
                    gatt.close()
                    // Re-scan after delay
                    handler.postDelayed({ startScan() }, 5000)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed: $status")
                return
            }
            val ancsService = gatt.getService(ANCS_SERVICE)
            if (ancsService == null) {
                Log.w(TAG, "ANCS service not found on this device")
                return
            }
            Log.i(TAG, "ANCS service discovered")

            // Subscribe to Notification Source
            val notifSource = ancsService.getCharacteristic(NOTIFICATION_SOURCE)
            if (notifSource != null) {
                gatt.setCharacteristicNotification(notifSource, true)
                val cccd = notifSource.getDescriptor(CCCD)
                if (cccd != null) {
                    cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(cccd)
                }
            }

            // Subscribe to Data Source
            val dataSource = ancsService.getCharacteristic(DATA_SOURCE)
            if (dataSource != null) {
                gatt.setCharacteristicNotification(dataSource, true)
                val cccd = dataSource.getDescriptor(CCCD)
                if (cccd != null) {
                    cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(cccd)
                }
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val uuid = characteristic.uuid
            val data = characteristic.value ?: return

            when (uuid) {
                NOTIFICATION_SOURCE -> handleNotificationSource(data)
                DATA_SOURCE -> handleDataSource(data)
            }
        }
    }

    // ---- ANCS Notification Source parser ---------------------------------
    //
    // Format: [EventID:1][EventFlags:1][CategoryID:1][CategoryCount:1][NotificationUID:4]
    // EventID: 0=Added, 1=Modified, 2=Removed

    private var pendingNotificationUid: Int? = null

    private fun handleNotificationSource(data: ByteArray) {
        if (data.size < 8) return
        val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val eventId = buffer.get().toInt() and 0xFF
        val notificationUid = buffer.getInt(4) // offset 4, 4 bytes

        when (eventId) {
            0 -> { // Added
                pendingNotificationUid = notificationUid
                requestNotificationAttributes(notificationUid)
            }
            2 -> { // Removed
                Log.d(TAG, "Notification removed: UID=$notificationUid")
            }
        }
    }

    // ---- Request notification attributes via Control Point ----------------
    //
    // Format: [CommandID:1][NotificationUID:4][AttributeID:1][AttributeID:1]...
    // CommandID: 0 = GetNotificationAttributes
    // AttributeIDs: 0=AppIdentifier, 1=Title, 2=Subtitle, 3=Message, 4=MessageSize, 5=Date, 6=PositiveActionLabel, 7=NegativeActionLabel

    private fun requestNotificationAttributes(uid: Int) {
        val controlPoint = getControlPoint() ?: return
        // Request AppIdentifier (0), Title (1), Message (3), Date (5)
        val request = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        request.put(0) // CommandID: GetNotificationAttributes
        request.putInt(uid) // NotificationUID
        request.put(0) // AttributeID: AppIdentifier
        request.put(1) // AttributeID: Title
        request.put(3) // AttributeID: Message
        request.put(5) // AttributeID: Date
        controlPoint.value = request.array()
        gatt?.writeCharacteristic(controlPoint)
    }

    private fun getControlPoint(): BluetoothGattCharacteristic? {
        val gatt = gatt ?: return null
        val svc = gatt.getService(ANCS_SERVICE) ?: return null
        return svc.getCharacteristic(CONTROL_POINT)
    }

    // ---- Data Source parser -----------------------------------------------
    //
    // Format: [CommandID:1][NotificationUID:4][AttributeID:1][Length:2][Data:variable]
    // Multiple attributes can follow in one data source notification

    private var pendingNotif = AncsNotification("", "", "", "", 0L)

    private fun handleDataSource(data: ByteArray) {
        if (data.size < 6) return
        val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val commandId = buffer.get().toInt() and 0xFF
        if (commandId != 0) return // Not a GetNotificationAttributes response

        val uid = buffer.getInt()
        var offset = 5 // CommandID(1) + NotificationUID(4)

        while (offset + 3 < data.size) {
            val attrId = data[offset].toInt() and 0xFF
            offset += 1
            if (offset + 2 > data.size) break
            val len = (data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)
            offset += 2
            if (offset + len > data.size) break
            val value = if (len > 0) String(data, offset, len, Charsets.UTF_8) else ""
            offset += len

            when (attrId) {
                0 -> pendingNotif = pendingNotif.copy(appName = value) // AppIdentifier
                1 -> pendingNotif = pendingNotif.copy(title = value)   // Title
                3 -> pendingNotif = pendingNotif.copy(body = value)    // Message
                5 -> { // Date — ISO 8601 string
                    try {
                        // Parse ISO 8601 to timestamp
                        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
                        val date = sdf.parse(value.take(19))
                        pendingNotif = pendingNotif.copy(timestampMs = date?.time ?: System.currentTimeMillis())
                    } catch (_: Exception) {
                        pendingNotif = pendingNotif.copy(timestampMs = System.currentTimeMillis())
                    }
                }
            }
        }

        // If we got at least title or body, emit the notification
        if (pendingNotif.title.isNotEmpty() || pendingNotif.body.isNotEmpty()) {
            val notif = pendingNotif.copy(notifId = uid.toString())
            handler.post { onNotification?.invoke(notif) }
            pendingNotif = AncsNotification("", "", "", "", 0L)
        }
    }
}
