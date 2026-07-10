package com.wearlink.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.Collections
import java.util.UUID

/// BLE peripheral (GATT server) + low-duty advertiser. Transport only:
/// frames (already encoded by the Dart codec) are forwarded raw to/from
/// Flutter via WearLinkBlePlugin. Decode lives in Dart.
///
/// Battery: advertise ADVERTISE_MODE_LOW_POWER at 1s idle. Plugin switches to
/// a faster advertising set when a call event is pending (Phase 3).
class BlePeripheralService(private val context: Context) {

    private companion object {
        const val TAG = "WearLink/Ble"
    }

    enum class ConnState { DISCONNECTED, CONNECTING, CONNECTED }

    var onConnState: ((ConnState) -> Unit)? = null
    var onFrame: ((UUID, ByteArray) -> Unit)? = null   // uuid, raw frame bytes (from phone write)
    var onMtuChanged: ((Int) -> Unit)? = null           // surfaced MTU from central request
    var onError: ((String) -> Unit)? = null              // start/operation failure feedback

    private val handler = Handler(Looper.getMainLooper())
    private var server: BluetoothGattServer? = null
    private var adapter: BluetoothAdapter? = null
    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    private var connectedDevice: BluetoothDevice? = null
    private val notifying = Collections.synchronizedSet(mutableSetOf<UUID>())

    /** Negotiated ATT MTU (default 23 until onMtuChanged fires). Used to cap FE10
     *  read responses so iOS's transparent long-read (ATT_READ_BLOB) reassembly
     *  works when the framed DeviceInfo exceeds a single ATT payload. */
    @Volatile private var negotiatedMtu: Int = 23

    @Volatile var connState = ConnState.DISCONNECTED
        private set

    /**
     * Framed DeviceInfo bytes returned on an FE10 read. Built by Dart (DeviceInfo
     * protobuf + PacketCodec framing) and cached here because the GATT read callback
     * runs on the binder thread and cannot round-trip to Flutter. Dart refreshes
     * this on the health timer tick so the battery reading stays current.
     */
    @Volatile var deviceInfoResponse: ByteArray? = null
        private set

    /** Snapshot of device facts for the DeviceInfo protobuf: model, firmware
     *  (Android release), battery capacity (%), and preferred MTU. */
    fun deviceInfoSnapshot(): Map<String, Any> {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val battery = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 0
        return mapOf(
            "model" to Build.MODEL,
            "firmware" to Build.VERSION.RELEASE,
            "battery" to battery,
            "mtu" to 247
        )
    }

    fun setDeviceInfoResponse(frame: ByteArray) {
        deviceInfoResponse = frame
    }

    /** Start the GATT server. Returns false if Bluetooth is off or server creation fails. */
    fun start(): Boolean {
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = mgr?.adapter
        if (adapter?.isEnabled != true) {
            Log.e(TAG, "start: Bluetooth adapter not enabled")
            handler.post { onError?.invoke("Bluetooth adapter is not enabled") }
            return false
        }
        server = mgr?.openGattServer(context, gattCallback)
        if (server == null) {
            Log.e(TAG, "start: openGattServer returned null (BLE perms missing?)")
            handler.post { onError?.invoke("Failed to open GATT server") }
            return false
        }
        Log.i(TAG, "start: GATT server opened")
        setupService()
        return true
    }

    fun stop() {
        stopAdvertising()
        connectedDevice?.let { server?.cancelConnection(it) }
        server?.close()
        server = null
    }

    // ---- Advertising -----------------------------------------------------

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "advertise onStartSuccess — watch is broadcasting service UUID")
        }
        override fun onStartFailure(errorCode: Int) {
            // ADVERTISE_FAILED_FEATURE_UNSUPPORTED = 1
            // ADVERTISE_FAILED_TOO_MANY_ADVERTISERS = 2
            // ADVERTISE_FAILED_ALREADY_STARTED = 3
            // ADVERTISE_FAILED_DATA_TOO_LARGE = 4
            // ADVERTISE_FAILED_INTERNAL_ERROR = 5
            // The most common cause on a fresh install: BLUETOOTH_ADVERTISE not
            // granted at runtime (API 31+) — the advertiser rejects with
            // FEATURE_UNSUPPORTED / INTERNAL_ERROR instead of a permission error.
            Log.e(TAG, "advertise onStartFailure errorCode=$errorCode — " +
                "watch NOT discoverable. Likely missing BLUETOOTH_ADVERTISE/SCAN/CONNECT " +
                "runtime permission, or BT off.")
            handler.post { onError?.invoke("Advertise failed: errorCode=$errorCode") }
        }
    }

    fun startAdvertising() {
        val a = advertiser ?: adapter?.bluetoothLeAdvertiser
        if (a == null) {
            Log.e(TAG, "startAdvertising: bluetoothLeAdvertiser is null (BLE perms/BT off)")
            return
        }
        advertiser = a
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setConnectable(true)
            .setTimeout(0) // advertise until stopped
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(Uuids.service))
            .build()
        Log.i(TAG, "startAdvertising: requesting to advertise service UUID")
        a.startAdvertising(settings, data, advCallback)
    }

    fun stopAdvertising() {
        advertiser?.stopAdvertising(advCallback)
        advertiser = null
    }

    // ---- GATT service setup --------------------------------------------

    private fun setupService() {
        val gatt = server ?: return
        val svc = android.bluetooth.BluetoothGattService(
            Uuids.service,
            android.bluetooth.BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        for (uuid in Uuids.all) {
            val props = propsFor(uuid)
            val perms = permsFor(uuid)
            val c = BluetoothGattCharacteristic(uuid, props, perms)
            // CCCD descriptor so central can subscribe to notify chars.
            if (props and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                val cccd = BluetoothGattDescriptor(
                    UUID.fromString("00002902-0000-1000-8000-00805F9B34FB"),
                    BluetoothGattDescriptor.PERMISSION_WRITE
                )
                c.addDescriptor(cccd)
            }
            svc.addCharacteristic(c)
        }
        gatt.addService(svc)
    }

    private fun propsFor(uuid: UUID): Int {
        val p = BluetoothGattCharacteristic.PROPERTY_READ or
            BluetoothGattCharacteristic.PROPERTY_WRITE
        return when (uuid) {
            // Notify characteristics — the watch (GATT peripheral) pushes these to
            // the iPhone (central). A peripheral CANNOT write to a central; the only
            // peripheral→central data path is notify/indicate. FE20/FE30/FE50/FE60
            // are the stream/bidirectional chars, and FE31/FE41/FE51 are the ACTION
            // chars (CallAction/NotifAction/MusicCommand) the watch sends back to the
            // phone in response to user taps. Without NOTIFY (+CCCD) on these three,
            // the iPhone can never subscribe, `notifying` never contains them, and
            // notify() short-circuits — every watch→phone action silently dies.
            // (iOS already lists FE31/41/51 for subscription in GattClient.swift; it
            // only needs the watch to expose NOTIFY here.)
            Uuids.healthStream, Uuids.callEvent,
            Uuids.musicNowPlaying, Uuids.linkControl,
            Uuids.callAction, Uuids.notificationAction, Uuids.musicCommand ->
                p or BluetoothGattCharacteristic.PROPERTY_NOTIFY
            else -> p
        }
    }

    /** Return permissions matching the characteristic's properties. */
    private fun permsFor(uuid: UUID): Int {
        val props = propsFor(uuid)
        var perms = 0
        if (props and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
            perms = perms or BluetoothGattCharacteristic.PERMISSION_READ
        }
        if (props and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) {
            perms = perms or BluetoothGattCharacteristic.PERMISSION_WRITE
        }
        return perms
    }

    // ---- Outbound: watch -> phone via notify -----------------------------

    /**
     * Notify the connected central of a characteristic change.
     *
     * NOTE: This method calls [BluetoothGatt.notifyCharacteristicChanged] which
     * must run on the binder thread. The caller (Dart side via platform channel)
     * already invokes this from its own thread context, which is safe. Do NOT
     * call this from an arbitrary background thread without ensuring the binder
     * thread Looper is available.
     */
    fun notify(uuid: UUID, frame: ByteArray): Boolean {
        val gatt = server ?: return false
        val dev = connectedDevice ?: return false
        val svc = gatt.getService(Uuids.service) ?: return false
        val c = svc.getCharacteristic(uuid) ?: return false
        if (uuid !in notifying) return false   // central hasn't subscribed
        c.value = frame
        return gatt.notifyCharacteristicChanged(dev, c, false)
    }

    // ---- GATT callbacks -------------------------------------------------

    private val gattCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "GATT central CONNECTED: ${device.address}")
                    connectedDevice = device
                    stopAdvertising()
                    setConn(ConnState.CONNECTED)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "GATT central DISCONNECTED (status=$status)")
                    connectedDevice = null
                    notifying.clear()
                    setConn(ConnState.DISCONNECTED)
                    startAdvertising()
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            negotiatedMtu = mtu
            handler.post { onMtuChanged?.invoke(mtu) }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            val gatt = server
            if (characteristic.uuid == Uuids.deviceInfo) {
                // Return the Dart-built framed DeviceInfo protobuf. iOS reads FE10
                // once on discovery; the response flows through its frame decoder
                // to onPayload[deviceInfo]. Long reads may request offset > 0, so
                // slice from the cached bytes and echo the requested offset back.
                val resp = deviceInfoResponse
                when {
                    resp == null ->
                        gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, ByteArray(0))
                    offset < 0 || offset > resp.size ->
                        gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, 0, null)
                    offset == resp.size ->
                        // End of a long read whose length is an exact multiple of (MTU-1):
                        // an empty response tells CoreBluetooth the value is complete.
                        gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, ByteArray(0))
                    else -> {
                        // Cap each response to MTU-1 bytes (ATT_READ_RSP overhead is 1)
                        // so CoreBluetooth reassembles via ATT_READ_BLOB across reads.
                        val maxBytes = (negotiatedMtu - 1).coerceAtLeast(20)
                        val end = minOf(offset + maxBytes, resp.size)
                        val slice = if (offset == 0 && end == resp.size) resp
                                    else resp.copyOfRange(offset, end)
                        gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
                    }
                }
            } else {
                gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            try {
                onFrame?.invoke(characteristic.uuid, value)
            } catch (e: Exception) {
                Log.e("BlePeripheralService", "onCharacteristicWriteRequest failed", e)
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            try {
                // CCCD enable/disable notify subscription.
                val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
                if (descriptor.uuid == cccdUuid) {
                    val charUuid = descriptor.characteristic?.uuid
                    if (charUuid != null) {
                        if (value.isNotEmpty() && (value[0].toInt() and 0x01) != 0) {
                            notifying.add(charUuid)
                        } else {
                            notifying.remove(charUuid)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("BlePeripheralService", "onDescriptorWriteRequest failed", e)
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {}
    }

    private fun setConn(s: ConnState) {
        connState = s
        handler.post { onConnState?.invoke(s) }
    }
}
