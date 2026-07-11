package com.wearlink.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.util.Collections
import java.util.UUID

/// BLE peripheral (GATT server) + low-duty advertiser. Transport only:
/// frames (already encoded by the Dart codec) are forwarded raw to/from
/// Flutter via WearLinkBlePlugin. Decode lives in Dart.
///
/// Battery: advertise ADVERTISE_MODE_LOW_POWER at 1s idle. Plugin switches to
/// a faster advertising set when a call event is pending (Phase 3).
///
/// Implemented as a real Android foreground Service so the BLE advertiser
/// survives screen-off / process suspension. The OS keeps the process alive
/// (with a persistent notification) while the watch is connected, so iOS
/// central.connect() does not hang when the screen dims.
class BlePeripheralService : Service() {

    companion object {
        private const val TAG = "WearLink/Ble"
        const val CHANNEL_ID = "wearlink_ble"
        const val NOTIF_ID = 4242

        /// Singleton reference to the live service instance (set in onCreate,
        /// cleared in onDestroy). The plugin uses this to reach the GATT server
        /// without holding a direct construction reference (the system, not the
        /// plugin, instantiates the Service).
        @Volatile var instance: BlePeripheralService? = null

        // Static callback holders so the plugin can wire callbacks BEFORE the
        // service is created by the system. onCreate copies these into the
        // instance fields so events fired after creation reach Flutter and so
        // a system-recreated Service picks up the latest wiring.
        @Volatile var sOnConn: ((ConnState) -> Unit)? = null
        @Volatile var sOnFrame: ((UUID, ByteArray) -> Unit)? = null
        @Volatile var sOnMtu: ((Int) -> Unit)? = null
        @Volatile var sOnError: ((String) -> Unit)? = null

        /// Launch the service as a foreground service. Must be called while the
        /// activity is in the foreground (the Flutter "start" method channel
        /// call satisfies this — no background-launch restriction).
        fun launch(ctx: Context) {
            ContextCompat.startForegroundService(ctx, Intent(ctx, BlePeripheralService::class.java))
        }
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

    /** Diagnostic-only receiver for BluetoothDevice.ACTION_BOND_STATE_CHANGED.
     *  Logs the bond progression (BOND_NONE -> BOND_BONDING -> BOND_BONDED) so
     *  the LE Secure Connections pairing triggered by the encrypted FE10 read can
     *  be observed in logcat. Does NOT drive any logic — the stack handles the
     *  bond internally and iOS retries the read automatically. Registered with
     *  RECEIVER_NOT_EXPORTED to satisfy API 34+ receiver-export flags. */
    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            // Typed getParcelableExtra on API 33+ (TIRAMISU); the untyped reified
            // overload is deprecated there. Diagnostic-only, so a null device is fine.
            val dev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            else
                @Suppress("DEPRECATION") intent?.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
            val state = intent?.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE) ?: BluetoothDevice.BOND_NONE
            val prev = intent?.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.BOND_NONE) ?: BluetoothDevice.BOND_NONE
            Log.i(TAG, "bondStateChange ${dev?.address}: $prev -> $state " +
                "(BOND_NONE=10 BOND_BONDING=11 BOND_BONDED=12)")
        }
    }
    @Volatile private var bondReceiverRegistered = false

    /** Negotiated ATT MTU (default 23 until onMtuChanged fires). Used to cap FE10
     *  read responses so iOS's transparent long-read (ATT_READ_BLOB) reassembly
     *  works when the framed DeviceInfo exceeds a single ATT payload. */
    @Volatile private var negotiatedMtu: Int = 23

    @Volatile var connState = ConnState.DISCONNECTED
        private set

    /// True while the advertiser is actively running. Guards against
    /// ADVERTISE_FAILED_ALREADY_STARTED (errorCode 3), which happened because
    /// on disconnect we called startAdvertising() before the previous (connect
    /// -time) advertiser instance had fully torn down — making the watch
    /// permanently invisible after the first connection attempt.
    @Volatile private var isAdvertising = false

    /// True once we have dropped the device name from the scan response after
    /// an ADVERTISE_FAILED_DATA_TOO_LARGE (errorCode 1) failure. Prevents an
    /// infinite retry loop: a single name-overflow drops the name, then we keep
    /// advertising UUID-only (the same payload that worked in Phase 17).
    @Volatile private var nameDropped = false

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
        val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
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
    fun startEngine(): Boolean {
        val mgr = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = mgr?.adapter
        if (adapter?.isEnabled != true) {
            Log.e(TAG, "start: Bluetooth adapter not enabled")
            handler.post { onError?.invoke("Bluetooth adapter is not enabled") }
            return false
        }
        server = mgr?.openGattServer(this, gattCallback)
        if (server == null) {
            Log.e(TAG, "start: openGattServer returned null (BLE perms missing?)")
            handler.post { onError?.invoke("Failed to open GATT server") }
            return false
        }
        Log.i(TAG, "start: GATT server opened")
        setupService()
        return true
    }

    fun stopEngine() {
        stopAdvertising()
        connectedDevice?.let { server?.cancelConnection(it) }
        server?.close()
        server = null
    }

    // ---- Service lifecycle ----------------------------------------------

    override fun onCreate() {
        super.onCreate()
        instance = this
        // Wire static callbacks (set by the plugin before launch) into instance
        // fields so GATT callbacks reach Flutter.
        onConnState = sOnConn
        onFrame = sOnFrame
        onMtuChanged = sOnMtu
        onError = sOnError
        createNotificationChannel()
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("WearLink")
            .setContentText("Connected to phone")
            .setOngoing(true)
            .build()
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        ServiceCompat.startForeground(this, NOTIF_ID, notif, type)
        // Now start the engine (the old start() body): open GATT server +
        // setupService, then begin advertising immediately. Advertising in
        // onCreate (not via a later advertiseStart call) does two things:
        //   1. START_STICKY actually restores discoverability after a process
        //      kill — without this, a system-restarted Service would open the
        //      GATT server and sit idle (invisible) until Dart re-called
        //      advertiseStart, which never happens if the app isn't foreground.
        //   2. Removes the advertiseStart race: startForegroundService is async,
        //      so a Dart advertiseStart fired right after 'start' could land
        //      before onCreate runs (instance==null → silent no-op). Starting
        //      here makes the first-connect path deterministic. The isAdvertising
        //      guard makes the later Dart advertiseStart call idempotent.
        startEngine()
        // Register the bond-state receiver for logcat diagnosis of the LE Secure
        // Connections pairing triggered by the encrypted FE10 read. Diagnostic
        // only — does not drive any logic.
        try {
            ContextCompat.registerReceiver(
                this, bondReceiver,
                IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            bondReceiverRegistered = true
        } catch (e: Exception) {
            Log.e(TAG, "onCreate: failed to register bondReceiver", e)
        }
        startAdvertising()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY so the OS restarts the advertiser if the process is killed.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        // Cancel any pending handler work (notably the 300ms delayed re-advertise
        // scheduled on disconnect) BEFORE tearing the engine down. Without this,
        // a 'stop' arriving within 300ms of a disconnect lets startAdvertising()
        // fire AFTER onDestroy — starting a fresh advertiser on a dead service
        // (no live GATT server) and leaking it.
        handler.removeCallbacksAndMessages(null)
        // Unregister the bond-state receiver (diagnostic). Guarded so a failed
        // registration in onCreate does not throw on unregister.
        if (bondReceiverRegistered) {
            try { unregisterReceiver(bondReceiver) } catch (_: Exception) {}
            bondReceiverRegistered = false
        }
        stopEngine()
        instance = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm?.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "WearLink BLE",
                    NotificationManager.IMPORTANCE_LOW
                )
                nm?.createNotificationChannel(channel)
            }
        }
    }

    // ---- Advertising -----------------------------------------------------

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            Log.i(TAG, "advertise onStartSuccess — watch is broadcasting service UUID")
        }
        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            // ADVERTISE_FAILED_DATA_TOO_LARGE = 1
            // ADVERTISE_FAILED_TOO_MANY_ADVERTISERS = 2
            // ADVERTISE_FAILED_ALREADY_STARTED = 3
            // ADVERTISE_FAILED_INTERNAL_ERROR = 4
            // ADVERTISE_FAILED_FEATURE_UNSUPPORTED = 5
            // (Values verified against AOSP AdvertiseCallback.java — the prior
            // comment had DATA_TOO_LARGE and FEATURE_UNSUPPORTED swapped and
            // INTERNAL_ERROR wrong.)
            // errorCode 3 (ALREADY_STARTED) means a previous advertise instance
            // is still tearing down. Retry once after a short delay instead of
            // giving up — otherwise the watch stays invisible until app restart.
            if (errorCode == 3) {
                Log.w(TAG, "advertise onStartFailure errorCode=3 (ALREADY_STARTED) — retrying in 300ms")
                handler.postDelayed({ startAdvertising() }, 300)
                return
            }
            // DATA_TOO_LARGE (errorCode 1) happens when the scan-response payload
            // (device name) plus overhead exceeds 31 bytes — e.g. a long BT adapter
            // name like "Galaxy Watch7". Retry ONCE with a name-less scan response
            // so the watch stays discoverable (UUID-only, the Phase 17 payload).
            if (errorCode == 1 && !nameDropped) {
                nameDropped = true
                Log.w(TAG, "advertise onStartFailure errorCode=1 (DATA_TOO_LARGE) " +
                    "— dropping device name from scan response and retrying")
                handler.postDelayed({ startAdvertising() }, 300)
                return
            }
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
        if (isAdvertising) {
            Log.i(TAG, "startAdvertising: already advertising — skip")
            return
        }
        val a = advertiser ?: adapter?.bluetoothLeAdvertiser
        if (a == null) {
            Log.e(TAG, "startAdvertising: bluetoothLeAdvertiser is null (BLE perms/BT off)")
            return
        }
        advertiser = a
        // LOW_LATENCY + HIGH_TX while disconnected: advertise ~every 100ms at
        // high power so the iPhone's duty-cycled scan (2s on / 8s off) reliably
        // catches us on first connect. Battery cost is bounded because we
        // stopAdvertising() the moment a central connects (onConnectionStateChange).
        // LOW_POWER/LOW_TX (1s, weak) was marginal for first-time discovery — the
        // watch advertised but iOS often missed it within a 2s scan window.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0) // advertise until stopped
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(Uuids.service))
            .build()
        // Scan response carries the watch's Bluetooth name so iOS shows a
        // friendly name in the pairing dialog instead of a bare MAC. It gets its
        // own 31-byte budget separate from the primary advData (which holds the
        // 128-bit service UUID), so the name cannot overflow the primary packet.
        // If a previous attempt failed with DATA_TOO_LARGE (errorCode 1), the
        // name is dropped here and we advertise UUID-only — the Phase 17 payload.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(!nameDropped)
            .build()
        Log.i(TAG, "startAdvertising: requesting to advertise service UUID" +
            (if (nameDropped) " (name dropped)" else " + device name in scan response"))
        a.startAdvertising(settings, data, scanResponse, advCallback)
    }

    fun stopAdvertising() {
        if (!isAdvertising && advertiser == null) return
        advertiser?.stopAdvertising(advCallback)
        advertiser = null
        isAdvertising = false
        // Reset the name-overflow fallback so the next advertising attempt
        // re-tries WITH the device name (the adapter name may have been
        // shortened since the last DATA_TOO_LARGE). The errorCode-1 guard
        // prevents any loop if it still overflows.
        nameDropped = false
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

    /** Return permissions matching the characteristic's properties.
     *
     *  FE10 (DeviceInfo) is the ONLY encrypted characteristic: it is the first
     *  char iOS READS after connect+subscribe. With PERMISSION_READ_ENCRYPTED,
     *  the Bluedroid stack returns GATT_INSUFFICIENT_AUTHENTICATION (0x05) to
     *  an unbonded iOS central WITHOUT invoking onCharacteristicReadRequest, so
     *  iOS auto-shows the system "Pair" dialog and retries the read after the
     *  LE Secure Connections bond completes. Every other characteristic stays
     *  unencrypted so service discovery, CCCD subscribe writes, and all
     *  health/call/music traffic keep working on an unpaired link — graceful
     *  degradation if the user dismisses the pairing dialog (only DeviceInfo is
     *  lost, not function). The CCCD descriptor (setupService) stays
     *  PERMISSION_WRITE (unencrypted) so pre-pairing subscribes still succeed. */
    private fun permsFor(uuid: UUID): Int {
        val props = propsFor(uuid)
        var perms = 0
        if (props and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
            perms = if (uuid == Uuids.deviceInfo)
                BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED
            else
                BluetoothGattCharacteristic.PERMISSION_READ
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

        override fun onServiceAdded(status: Int, service: android.bluetooth.BluetoothGattService) {
            Log.i(TAG, "onServiceAdded status=$status (0=success) service=${service.uuid} — GATT service registered")
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "GATT central CONNECTED: ${device.address} (status=$status)")
                    connectedDevice = device
                    stopAdvertising()
                    setConn(ConnState.CONNECTED)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "GATT central DISCONNECTED (status=$status)")
                    connectedDevice = null
                    notifying.clear()
                    setConn(ConnState.DISCONNECTED)
                    // Delay re-advertise ~300ms so the previous advertiser
                    // instance fully tears down — avoids ALREADY_STARTED (errorCode 3).
                    handler.postDelayed({ startAdvertising() }, 300)
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            negotiatedMtu = mtu
            Log.i(TAG, "MTU negotiated=$mtu")
            handler.post { onMtuChanged?.invoke(mtu) }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            Log.i(TAG, "READ req char=${characteristic.uuid} offset=$offset")
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
            Log.i(TAG, "WRITE req char=${characteristic.uuid} offset=$offset len=${value.size} responseNeeded=$responseNeeded")
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
                            Log.i(TAG, "CCCD ENABLE notify for char=$charUuid")
                        } else {
                            notifying.remove(charUuid)
                            Log.i(TAG, "CCCD DISABLE notify for char=$charUuid")
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