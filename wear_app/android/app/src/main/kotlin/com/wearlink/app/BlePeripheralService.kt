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
        /// How long to advertise at LOW_LATENCY/HIGH_TX for fast first discovery
        /// before dropping to LOW_POWER/MEDIUM to save battery while staying
        /// connectable. 30s covers the iPhone's 2s-on/8s-off scan duty cycle
        /// several times so the first discovery window is not missed.
        private const val FAST_ADVERTISE_MS = 30_000L

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
    // server + connectedDevice are @Volatile: written on the GATT binder thread
    // (onConnectionStateChange) but read on the platform-channel thread (notify()
    // from Dart). Without @Volatile the platform thread could see a stale null or
    // a freed device after a disconnect, NPE-ing the watch→iPhone notify path.
    @Volatile private var server: BluetoothGattServer? = null
    private var adapter: BluetoothAdapter? = null
    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    @Volatile private var connectedDevice: BluetoothDevice? = null
    private val notifying = Collections.synchronizedSet(mutableSetOf<UUID>())
    private var wakeLock: android.os.PowerManager.WakeLock? = null

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

    /// P1 battery tuning: advertise LOW_LATENCY/HIGH_TX for FAST_ADVERTISE_MS
    /// after each (re)start so the iPhone's scan cycle finds us fast, then drop
    /// to LOW_POWER/MEDIUM to save battery while staying connectable. Reset to
    /// false on every disconnect so a reconnect re-enters the fast window.
    @Volatile private var lowPowerAdvertise = false

    /// Scheduled downgrade from the fast discovery window to low-power advertising.
    /// Removed on stop/disconnect so a fresh fast window always starts cleanly.
    private val downgradeToLowPower = Runnable {
        if (isAdvertising) {
            Log.i(TAG, "advertise: fast window elapsed — downgrading to LOW_POWER to save battery")
            stopAdvertising()
            lowPowerAdvertise = true
            startAdvertising()
        }
    }

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
            .setContentText("Listening for phone")
            .setOngoing(true)
            .build()
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        ServiceCompat.startForeground(this, NOTIF_ID, notif, type)
        Log.i(TAG, "onCreate: FGS started as foreground (type=connectedDevice) — advertiser will survive screen-off")
        // Hold a PARTIAL_WAKE_LOCK so the CPU does not sleep on screen-off and
        // freeze the advertiser/GATT thread. The FGS alone keeps the process
        // alive; the wake lock keeps it SCHEDULABLE. WAKE_LOCK perm is in the
        // manifest. Released in onDestroy.
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            wakeLock = pm?.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "WearLink:Ble")
            wakeLock?.acquire()
            Log.i(TAG, "onCreate: PARTIAL_WAKE_LOCK acquired")
        } catch (e: Exception) {
            Log.e(TAG, "onCreate: wakeLock acquire failed", e)
        }
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
        val engineOk = startEngine()
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
        if (engineOk) startAdvertising()
        else Log.e(TAG, "onCreate: engine failed — not advertising")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand: startId=$startId flags=$flags intent=${intent?.action ?: "null"} — service (re)started")
        // START_STICKY so the OS restarts the advertiser if the process is killed.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.i(TAG, "onDestroy: FGS stopping — advertiser/engine tearing down")
        // Log a stack trace to identify WHO is killing the service. If the trace
        // shows ActivityManagerService → the system is killing it (battery mgmt).
        // If it shows our own code → stopService() was called from the plugin.
        Log.i(TAG, "onDestroy: caller stack trace:\n${android.util.Log.getStackTraceString(Throwable())}")
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
        // Release the wake lock held since onCreate.
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
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
                    NotificationManager.IMPORTANCE_DEFAULT
                )
                nm?.createNotificationChannel(channel)
            }
        }
    }

    // ---- Advertising -----------------------------------------------------
    // Legacy BluetoothLeAdvertiser.startAdvertising is used (NOT the modern
    // startAdvertisingSet) because the legacy API produces a Legacy:true,
    // LE_1M-ph advert — confirmed via `dumpsys bluetooth_manager` GATT
    // Advertiser Map — which iOS CoreBluetooth's scanForPeripherals reliably
    // discovers. The modern startAdvertisingSet produced an extended advert
    // (Legacy:false) that iOS's scan never saw ("no watch found" on every
    // scan cycle). The `le_connectability_state: DISARMED` shown in dumpsys
    // is a stale/misleading shim metric: the actual advert params report
    // Connectable=true, which is what the controller advertises.

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            Log.i(TAG, "advertise onStartSuccess — watch is broadcasting service UUID (connectable legacy) " +
                "mode=${if (lowPowerAdvertise) "LOW_POWER" else "LOW_LATENCY"}")
            // P1: only schedule the downgrade from the fast window. The low-power
            // restart (lowPowerAdvertise=true) is the steady state — no further
            // downgrade. Replace any stale pending downgrade first.
            if (!lowPowerAdvertise) {
                handler.removeCallbacks(downgradeToLowPower)
                handler.postDelayed(downgradeToLowPower, FAST_ADVERTISE_MS)
            }
        }
        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            // ADVERTISE_FAILED_DATA_TOO_LARGE=1, TOO_MANY_ADVERTISERS=2,
            // ALREADY_STARTED=3, INTERNAL_ERROR=4, FEATURE_UNSUPPORTED=5.
            if (errorCode == 3) {
                Log.w(TAG, "advertise onStartFailure errorCode=3 (ALREADY_STARTED) — retrying in 300ms")
                handler.postDelayed({ startAdvertising() }, 300)
                return
            }
            if (errorCode == 1 && !nameDropped) {
                nameDropped = true
                Log.w(TAG, "advertise onStartFailure errorCode=1 (DATA_TOO_LARGE) " +
                    "— dropping device name from scan response and retrying")
                handler.postDelayed({ startAdvertising() }, 300)
                return
            }
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
        // P1: fast window = LOW_LATENCY + HIGH_TX for quick first discovery;
        // steady state = LOW_POWER + MEDIUM to save battery while still
        // connectable. The 4-arg overload carries the device name in a separate
        // scan-response packet (its own 31-byte budget) so the 128-bit service
        // UUID fits in the primary advData.
        val mode = if (lowPowerAdvertise) AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                   else AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
        val tx = if (lowPowerAdvertise) AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
                 else AdvertiseSettings.ADVERTISE_TX_POWER_HIGH
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(mode)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(tx)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(Uuids.service))
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(!nameDropped)
            .build()
        Log.i(TAG, "startAdvertising: requesting to advertise service UUID" +
            (if (nameDropped) " (name dropped)" else " + device name in scan response") +
            " (connectable legacy, ${if (lowPowerAdvertise) "LOW_POWER/MED" else "LOW_LAT/HIGH"})")
        a.startAdvertising(settings, data, scanResponse, advCallback)
    }

    fun stopAdvertising() {
        if (!isAdvertising && advertiser == null) return
        handler.removeCallbacks(downgradeToLowPower)
        try { advertiser?.stopAdvertising(advCallback) } catch (_: Exception) {}
        advertiser = null
        isAdvertising = false
        // Reset the name-overflow fallback so the next attempt re-tries WITH the
        // device name. The errorCode==1 guard prevents any loop.
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
     *  ALL characteristics are UNENCRYPTED (PERMISSION_READ / PERMISSION_WRITE).
     *  This reverts the Phase 18 encrypted-FE10 experiment: marking FE10
     *  (DeviceInfo) PERMISSION_READ_ENCRYPTED triggered INSUFFICIENT_AUTH on
     *  the iPhone's FE10 read, iOS dropped the link to re-pair, and the partial
     *  handshake left a stale bond — subsequent connect() hung waiting for
     *  encryption that never settled (Phase 18 fix-3, decisive). The
     *  unencrypted baseline is what proved a stable connect.
     *
     *  Bonding is re-attempted in Phase 20.5 ONLY after the unencrypted link is
     *  rock-solid, and is gated on a prior native Bluetooth Settings classic
     *  bond so the encrypted FE10 read uses cross-transport key derivation
     *  instead of a fresh LE pair. Do NOT use PERMISSION_*_ENCRYPTED_MITM
     *  (forces a 6-digit passkey). The CCCD descriptor (setupService) stays
     *  PERMISSION_WRITE (unencrypted) so notify subscriptions work without
     *  re-pairing. */
    private fun permsFor(uuid: UUID): Int {
        val props = propsFor(uuid)
        var perms = 0
        if (props and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
            perms = BluetoothGattCharacteristic.PERMISSION_READ
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
                    // A central connect pauses the controller-level advertiser. If
                    // the CONNECTED callback did not fire (a rapid connect/drop),
                    // stopAdvertising() never ran and isAdvertising is stale true.
                    // The re-advertise guard would then skip ("already advertising
                    // — skip"), leaving the watch invisible. Reset unconditionally
                    // before re-advertise. nameDropped is preserved so an overflowed
                    // device name is not retried every reconnect cycle.
                    isAdvertising = false
                    advertiser = null
                    // P1: a reconnect is a fresh discovery — re-enter the fast
                    // LOW_LATENCY window and cancel any stale low-power downgrade.
                    handler.removeCallbacks(downgradeToLowPower)
                    lowPowerAdvertise = false
                    // Delay re-advertise ~300ms so the previous advertiser instance
                    // fully tears down — avoids ALREADY_STARTED (errorCode 3).
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

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            // P2: a non-GATT_SUCCESS notify means the central dropped, unsubscribed,
            // or the queue backed up — the frame may not have been delivered. Surface
            // it to Dart so feature code can react (e.g. stop streaming, drop the
            // session) instead of silently assuming delivery. Never swallow errors.
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "onNotificationSent FAILED status=$status to ${device.address} " +
                    "— central dropped/unsubscribed or queue backed up")
                handler.post { onError?.invoke("notify send failed status=$status") }
            }
        }
    }

    private fun setConn(s: ConnState) {
        connState = s
        handler.post { onConnState?.invoke(s) }
    }
}