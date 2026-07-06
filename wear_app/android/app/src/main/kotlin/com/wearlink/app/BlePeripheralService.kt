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
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.util.UUID

/// BLE peripheral (GATT server) + low-duty advertiser. Transport only:
/// frames (already encoded by the Dart codec) are forwarded raw to/from
/// Flutter via WearLinkBlePlugin. Decode lives in Dart.
///
/// Battery: advertise ADVERTISE_MODE_LOW_POWER at 1s idle. Plugin switches to
/// a faster advertising set when a call event is pending (Phase 3).
class BlePeripheralService(private val context: Context) {

    enum class ConnState { DISCONNECTED, CONNECTING, CONNECTED }

    var onConnState: ((ConnState) -> Unit)? = null
    var onFrame: ((UUID, ByteArray) -> Unit)? = null   // uuid, raw frame bytes (from phone write)

    private val handler = Handler(Looper.getMainLooper())
    private var server: BluetoothGattServer? = null
    private var adapter: BluetoothAdapter? = null
    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    private var connectedDevice: BluetoothDevice? = null
    private val notifying = mutableSetOf<UUID>()

    @Volatile var connState = ConnState.DISCONNECTED
        private set

    fun start() {
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = mgr?.adapter
        server = mgr?.openGattServer(context, gattCallback)
        setupService()
    }

    fun stop() {
        stopAdvertising()
        connectedDevice?.let { server?.cancelConnection(it) }
        server?.close()
        server = null
    }

    // ---- Advertising -----------------------------------------------------

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {}
        override fun onStartFailure(errorCode: Int) {}
    }

    fun startAdvertising() {
        val a = advertiser ?: adapter?.bluetoothLeAdvertiser ?: return
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
            val perms = BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
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
            Uuids.healthStream, Uuids.callEvent,
            Uuids.musicNowPlaying, Uuids.linkControl ->
                p or BluetoothGattCharacteristic.PROPERTY_NOTIFY
            else -> p
        }
    }

    // ---- Outbound: watch -> phone via notify -----------------------------

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
                    connectedDevice = device
                    stopAdvertising()
                    setConn(ConnState.CONNECTED)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    connectedDevice = null
                    notifying.clear()
                    setConn(ConnState.DISCONNECTED)
                    startAdvertising()
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            // Phone requested larger MTU. Surface to plugin if needed.
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            val gatt = server
            // DeviceInfo is the only readable char with real content.
            val resp: ByteArray = if (characteristic.uuid == Uuids.deviceInfo) {
                // TODO Phase 1+: return encoded DeviceInfo proto.
                "WearLink/0.1".toByteArray()
            } else ByteArray(0)
            gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, resp)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            onFrame?.invoke(characteristic.uuid, value)
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
            // CCCD enable/disable notify subscription.
            if (descriptor.uuid.toString()
                    .equals("00002902-0000-1000-8000-00805F9B34FB", ignoreCase = true)) {
                val charUuid = descriptor.characteristic?.uuid
                if (charUuid != null) {
                    if (value.isNotEmpty() && (value[0].toInt() and 0x01) != 0) {
                        notifying.add(charUuid)
                    } else {
                        notifying.remove(charUuid)
                    }
                }
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