# WearLink — Progress Tracker

> Source of truth for project status. Update after each work session.
> Architecture spec: see `Software-Structure.md`.

Last updated: 2026-07-11 (Phase 14 — joint iOS + Wear OS interconnect audit + fixes)

---

## Project Status: **Phase 7 complete — all 49 wear_app issues fixed, flutter analyze clean**

Verified locally (Linux host):
- `flutter analyze` → **No issues found** (was 49 issues: fixed watchSignal→SignalBuilder migration, PbList protobuf compat, deprecated debugLabel→SignalOptions, unused imports)
- `flutter test` → **9/9 pass** (PacketCodec round-trip/CRC-8 0xF4/reassembly + widget boot smoke)
- `flutter build apk --debug` → **success** (`build/app/outputs/flutter-apk/app-debug.apk`)
  → proves Kotlin (GATT server + HealthCollector + plugins) + Gradle + Wear OS manifest compile.
- Dart proto codegen → `wear_app/lib/gen/wearlink.pb.dart` (compatible with protobuf ^3.1.0)

NOT verified locally (impossible on Linux):
- iOS native app build (needs macOS + XcodeGen + CocoaPods + protoc). CI workflow `.github/workflows/build-ios.yml` is the verify path — push to `main` to run it and download the SideStore IPA artifact.
- On-device BLE round-trip on iPhone 14 Pro + Galaxy Watch 7 (needs both devices).

---

## Decisions (locked)

| Decision | Choice |
|---|---|
| iOS stack | Native Swift / SwiftUI + **CocoaPods** |
| Wear OS stack | **Flutter** + **signals_dart** + native Kotlin platform channels (BLE peripheral + Health Services) |
| BLE roles | **iOS = Central**, **Watch = Peripheral** |
| Wire protocol | Custom GATT service + protobuf payloads (shared `protocol/`) |
| Pairing | Bonded LE Secure Connections |
| Audio routing | Not attempted (platform-blocked) |
| Notification scope | Plumbing only; 3rd-party forwarding blocked by iOS sandbox |
| Music scope | Own-app control feasible; system control blocked |

---

## Roadmap

Legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked by platform

### Phase 0 — Project scaffolding
- [x] Create `wear_app/` directory; move root Flutter project into it
- [x] Update `pubspec.yaml` name, add `signals`, `protobuf`, `protoc_plugin` deps
- [x] Configure Wear OS `android` module for watch form factor (minSdk 30, watch feature, permissions, Health Services + WorkManager deps)
- [x] Create `ios_app/` native Swift project scaffold (project.yml for XcodeGen, NOT .xcodeproj — generate on macOS)
- [x] Add `Podfile` (SwiftProtobuf + Zip), Info.plist, entitlements, NotificationServiceExtension target
- [x] Create `protocol/` + `GATT.md` + `codec.md` + `proto/wearlink.proto` + README
- [ ] Set up protoc codegen for Swift (ios) and Dart (wear) — tooling install only, run on macOS
- [ ] Verify `flutter pub get` + `xcodegen generate` + `pod install` succeed (needs macOS)

### Phase 1 — BLE link (foundation)
- [x] Define GATT service + characteristics in `protocol/GATT.md`
- [x] Implement packet codec (framing + CRC8/SMBUS-style + chunking) — both sides, unit-tested (Swift `PacketCodec.swift` + `PacketCodecTests.swift`; Dart `packet_codec.dart` + `packet_codec_test.dart`; known-answer vector 0xF4 synced)
- [x] Watch: native Kotlin `BlePeripheralService.kt` — advertiser + `BluetoothGattServer` + CCCD notify
- [x] Watch: `ble_peripheral_channel.dart` platform bridge (MethodChannel + EventChannel) + `ble_signal.dart` (signals_dart)
- [x] Watch: `WearLinkBlePlugin.kt` FlutterPlugin registered in `MainActivity`
- [x] iOS: `BLEManager.swift` (CBCentralManager, duty-cycled scan) + `GattClient.swift` (discover/subscribe + reassembly + dispatch)
- [ ] Pairing/bonding flow + reconnect on drop (basic reconnect scan present; explicit bonding UX pending)
- [x] Link Control heartbeat + ack (iOS sends heartbeat, echoes inbound LinkControl)
- [x] Build verification (Wear OS): `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK
- [ ] Verify: connect, send 1 byte round-trip, disconnect, reconnect — **needs real devices**
- [ ] Integration test on Wear OS device: `flutter test integration_test/app_test.dart -d <wear-os>` (harness added; no emulator on host)

### Phase 2 — Health data sync
- [x] Watch: `HealthCollector.kt` via Wear OS Health Services (passive HR/steps/calories/distance + sleep detection + active HR)
- [x] Watch: `HealthServicesPlugin.kt` platform channel bridge
- [x] Watch: `health_services_channel.dart` + `health_signal.dart` (signals_dart with BLE buffer)
- [x] Watch: `health_screen.dart` UI (live HR, steps, calories, distance, sleep state)
- [x] Proto: added CALORIES + DISTANCE_METERS types
- [ ] Watch: batch + delta-compress + queue on disconnect
- [ ] Watch: `Health Stream` notify + `Health Control` write (interval config)
- [ ] iOS: receive, decode, dedupe, write to HealthKit (`Health/` + `Storage/HealthStore.swift`)
- [ ] HealthKit write permissions UX
- [ ] Replay queued samples on reconnect
- [ ] Battery measurement: 24 h passive idle log

### Phase 3 — Call handling
- [x] iOS: `CallController.swift` — CXCallObserver + CXProvider delegate + CNContactStore lookup
- [x] iOS: encode `CallEvent` proto → BLE write to `callEvent` characteristic
- [x] iOS: decode `CallAction` from watch → `CXTransaction` (accept/reject/end/mute)
- [x] Watch: `call_signal.dart` — reactive state (incomingCall, callActive, muted, outgoing)
- [x] Watch: `call_screen.dart` — circular UI (idle/incoming/active/outgoing states)
- [x] Watch: `CallAction` write → iOS via BLE
- [ ] Latency test: incoming call → watch render < 1.5 s
- [x] Document: call audio stays on phone (non-goal)

### Phase 4 — Notification forwarding
- [x] iOS: `NotificationForwarder.swift` — encode `WearNotification` proto → BLE write
- [x] iOS: decode `NotifAction` from watch (dismiss/reply)
- [x] Watch: `AncsClient.kt` — BLE central mode, ANCS service discovery + notification reading
- [x] Watch: `AncsPlugin.kt` + `ancs_channel.dart` — platform bridge
- [x] Watch: `notification_signal.dart` — reactive state (notifications list, unread count)
- [x] Watch: `notification_screen.dart` — circular UI (list, dismiss)
- [ ] NotificationServiceExtension app-group bridge (ANCS handles main path)
- [x] Document: 3rd-party forwarding via ANCS (unblocked!)

### Phase 5 — Music control
- [x] iOS: `MusicController.swift` — MPNowPlayingInfoCenter + MPRemoteCommandCenter
- [x] iOS: encode `MusicNowPlaying` proto → BLE notify
- [x] iOS: decode `MusicCommand` from watch → dispatch to command center
- [x] Watch: `music_signal.dart` — reactive state (nowPlaying, position, volume)
- [x] Watch: `music_screen.dart` — circular UI (art, transport, volume, seek)
- [ ] Album art downscale + send over BLE (≤2 KB)
- [x] Document: system-media control blocked (own-app only)

### Phase 6 — iOS UI Reconstruction
- [x] Create Views/ directory structure (Main, DeviceDetails, Music, Common)
- [x] Build component library: ToggleRow, DeviceCardView, DeviceIconView, SectionHeader
- [x] Implement DevicesListView (main screen with device card + feature grid + tip card)
- [x] Implement DeviceDetailsView (settings: General, Notifications, Health, Find Device, Device Management)
- [x] Implement DeviceInfoSection (device info table)
- [x] Implement MusicControlOptionsView (background color picker + display options)
- [x] Update RootView (replace TabView with DevicesListView as root)
- [x] Update AppContainer (add device + settings properties, HealthKit error handling)
- [x] Create Models/WearableDevice.swift + DeviceSettings

### Phase 7 — Code Audit & Optimization
- [x] Full codebase audit: 27-agent parallel review (iOS Swift + Wear OS Dart/Kotlin + CI/CD)
- [x] Document all 73 issues in Optimization.md
- [x] Fix 14 critical issues (crashes, data corruption, missing entitlements)
- [x] Fix 23 high-severity issues (resource leaks, fragile handlers, permission gaps)
- [x] Fix 17 medium-severity issues (unused deps, thread safety, error handling)
- [x] Fix 19 low-severity issues (accessibility, dead code, style)
- [x] Remove unused SwiftProtobuf + Zip pods from Podfile
- [x] Add app-group + aps-environment entitlements to both targets
- [x] Fix AncsClient.kt BufferOverflow (ByteBuffer.allocate(9))
- [x] Fix HealthCollector.kt executor shutdown (restartable)
- [x] Add Health Services permissions to AndroidManifest
- [x] Fix BLEManager.swift state machine (poweredOff handling)
- [x] Fix GattClient.swift reassembler (per-characteristic)
- [x] Fix ProtoSerialization.swift varint overflow guard
- [x] Fix MusicController.swift (noActionable, volume clamp, togglePlayPause)
- [x] Fix CallController.swift (deinit, dead code removal)
- [x] Fix CI/CD workflow (signing config, Xcode version pinning)

### Phase 8 — Comprehensive Review & Improvement Plan
- [x] 6-agent comprehensive review (iOS + Wear OS + protocol + research)
- [x] Identified 23 issues across 5 priority levels
- [x] Documented findings in progress.md

### Phase 9 — Connection Fixes (CRITICAL — BLE does not work)
- [x] **P1: Fix UUID mismatch** — Kotlin uses custom base `96812f26-...`, iOS/Dart use SIG base `0000XXXX-...`. Watch advertises one UUID, phone scans for another → devices never see each other. Fix: standardize all 3 platforms on one UUID base.
- [x] **P1: Fix health data never sent** — `drainBuffer()` never called on watch. Fix: add periodic timer that builds `HealthFrame` proto and sends to `FE20`.
- [x] **P1: Fix `assumeIsolated` in deinit** — NotificationForwarder + MusicController use `MainActor.assumeIsolated` in deinit; crashes if last ref released off main thread. Fix: capture values + `Task { @MainActor in }`.
- [x] **P1: Remove dead handler registration** — `NotificationForwarder.registerNotificationActionHandler()` called when `gatt` is nil → no-op. BLEManager already handles this.

### Phase 10 — Health Data Display
- [ ] **P2: Remove SpO2/HRV cards** — Health Services 1.1.0 doesn't support these. Remove or label "not available".
- [ ] **P2: Fix distance unit** — Show "km" when distance ≥ 1000m.
- [ ] **P2: Implement health data pipeline** — Watch-side timer to broadcast HealthFrame over BLE. (See P1)
- [ ] **P2: Add "Last updated" timestamp** — Show when health data was last received.

### Phase 11 — Stability
- [ ] **P3: Post `bleDidReconnect` notification** — Defined but never posted. Fix: post from BLEManager on reconnect.
- [ ] **P3: Add reconnection backoff** — Fixed 2s/8s scan drains battery when watch out of range. Fix: exponential backoff (2s, 4s, 8s, 16s, max 30s).
- [ ] **P3: Fix MTU mismatch** — Kotlin ignores MTU changes, iOS negotiates dynamically. Fix: surface MTU to Kotlin.
- [ ] **P3: Add heartbeat validation** — iOS sends heartbeat but never confirms receipt. Fix: track seq on echo, reconnect on missed heartbeats.

### Phase 12 — Feature Improvements
- [ ] **P4: Caller name lookup** — Always "Unknown". Fix: CNContactStore lookup by phone number.
- [ ] **P4: NotificationServiceExtension** — Passthrough only; never writes to app-group. Fix: implement UNNotificationServiceExtension to forward pushes.
- [ ] **P4: DeviceInfo from BLE** — Hardcoded "Galaxy Watch7". Fix: subscribe to `FE10` characteristic, decode `DeviceInfo` proto.
- [ ] **P4: Fix empty callId** — CallView simulator actions send empty callId. Fix: generate proper UUID.
- [ ] **P4: Fix music position drift** — Cumulative error in timer. Fix: use CACurrentMediaTime for precision.

### Phase 13 — Code Quality
- [ ] **P5: Remove empty stubs** — `SampleStore.swift`, `HealthSampleStore.swift`.
- [ ] **P5: Remove deprecated `synchronize()`** — Unnecessary since iOS 13.
- [ ] **P5: Remove duplicate ProtoModels** — `Generated/ProtoModels.swift` duplicates `Models/ProtoModels.swift`.
- [ ] **P5: Add BLE write error handling** — Silent failures in `gatt?.write()` calls.
- [ ] **P5: Document heartbeat format** — 8-byte payload undocumented.

### Phase 14 — Joint Interconnect Audit + Fixes (2026-07-11)
- [x] Fix iOS missing `NSBluetoothAlwaysUsageDescription` (permission prompt bug)
- [x] Fix Wear OS missing runtime BLE permissions (invisible watch bug)
- [x] Fix Wear OS build break (`GATT_INVALID_OFFSET`)
- [x] Fix Wear OS black screen on launch (move `runApp` to top) — **partial; see Phase 15**
- [x] Implement modern "Rounded" Dashboard UI for Wear OS (Status → Action Chip → Health Card → Feature List)

### Phase 15 — Wear OS startup root-cause fix (2026-07-11)
- [x] **Root cause of black screen**: `main()` called `runApp()` BEFORE constructing `healthSignal`/`gatt`/`bleChannel`/`healthChannel`. `ConnectionScreen.build` (Live Health Stats card) read `healthSignal.steps.value` on frame 1 → `LateInitializationError` → blank ErrorWidget. The "move runApp to top" fix in Phase 14 was insufficient because the late globals were still constructed after `await bleChannel.requestPermissions()`.
- [x] Apply "safe-start" pattern in `main()`: `WidgetsFlutterBinding.ensureInitialized()` first → construct ALL signals+channels synchronously → `runApp()` → then await perms + native start in background. UI renders immediately; permission dialogs overlay a live app.
- [x] Add `WidgetsFlutterBinding.ensureInitialized()` (required: channel constructors call `EventChannel.receiveBroadcastStream().listen()`).
- [x] Fix `widget_test.dart` setUpAll to init `healthSignal`+`healthChannel` (test pumps `WearLinkApp` directly, never calls `main()`). Mock `wearlink/health` method channel.
- [x] Fix analyze lints: `withOpacity` → `withValues(alpha:)` (main.dart + ui/components.dart), `${hr} BPM` → `$hr BPM`.
- [x] Verify: `flutter analyze` clean, `flutter test` 9/9, `flutter build apk --debug` OK.
- [ ] **Latent (not blocking)**: `WearLinkBlePlugin.requestBlePermissions` / `HealthServicesPlugin.requestHealthPermissions` fall back to `hasBlePerms()`/`hasBodySensors()` and return false when `activity==null` instead of deferring. Normal FlutterActivity path is fine (onAttachedToActivity fires before main); pre-warmed engine edge case would silently kill BLE/health.
- [ ] **Dead config**: AndroidManifest `<service>` entries for `.BlePeripheralService` + `.HealthServicesPlugin` are invalid (neither class extends `Service`); `FOREGROUND_SERVICE_CONNECTED_DEVICE`/`FOREGROUND_SERVICE_HEALTH` perms unused. Remove entries or implement real foreground services.
- [ ] **Dead code**: `lib/ui/components.dart` unused (main.dart uses inline `_StatItem`/`_FeatureCard`). Kept for now; delete or adopt.

### Phase 17 — Wear OS foreground service (unblocks iPhone connect) (2026-07-11)
- **Root cause of iPhone connect() hang**: `BlePeripheralService` was a plain class (not a `Service`) despite the manifest declaring it a `<service>`. Advertiser lived in the Flutter activity process → Wear OS suspended it seconds after screen-dim → iOS `central.connect()` hit a dead advertiser → L2CAP never completed → hang. Bridge app works because it runs a foreground service ("Service Mode") keeping the advertiser alive when the screen is off.
- [x] Convert `BlePeripheralService` to a real `android.app.Service` (foreground, type `connectedDevice`). Singleton `instance` + static `sOnConn/sOnFrame/sOnMtu/sOnError` callback holders (set by plugin before launch, copied to instance fields in `onCreate`).
- [x] `onCreate`: notification channel (O+ guard) → `ServiceCompat.startForeground` (`stat_sys_data_bluetooth`, `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`) → `startEngine()` → `startAdvertising()`. Advertising starts in onCreate so START_STICKY actually restores discoverability after a process kill AND removes the advertiseStart race (startForegroundService is async → instance could be null when Dart's advertiseStart lands).
- [x] `onStartCommand` returns `START_STICKY`. `onDestroy` calls `handler.removeCallbacksAndMessages(null)` before `stopEngine()` so the 300ms delayed re-advertise can't fire on a destroyed service (leak). Clears `instance`.
- [x] `WearLinkBlePlugin`: no longer constructs the service. `start`→`launch(ctx)` (startForegroundService). `advertiseStart/Stop`/`notify`/`getDeviceInfo`/`setDeviceInfo` reach via `BlePeripheralService.instance` (null-safe; `notify` returns false when no instance). `onDetachedFromEngine` stops the service AND nulls the static `sOn*` holders (so a system-restarted service doesn't wire stale lambdas). Permission code unchanged.
- [x] Verify: `flutter analyze` clean, `flutter build apk --debug` OK (173 MB APK). Adversarial review: 4 findings (3 MED, 1 LOW), all applied.
- [ ] Verify on device: reinstall watch APK; open WearLink watch (screen dims → advertiser must survive); on iPhone open BLE Logs → expect `Discovered watch` → `connecting` → `connected` → `didDiscoverServices` → `didDiscoverCharacteristics` → `Subscribed to 7 notify chars` → `Reading FE10`. Watch logcat should now show `GATT central CONNECTED` (milestone that never fired before).
- [ ] **Follow-up (Phase 18, not blocking)**: bonding (`PERMISSION_*_ENCRYPTED` + `setIncludeDeviceName(true)`) → iOS-initiated LE Secure Connections bond → iPhone appears in watch system BT settings (entry user expected) + reconnect after reboot.
- [ ] **Latent (pre-existing, out of scope)**: `notify()` reads non-volatile `server`/`connectedDevice` from platform-channel thread while `onConnectionStateChange` writes them on binder thread (TOCTOU). Wire `onMtuChanged`/`onError` to EventChannel (currently dropped — only conn+frame reach Flutter).
- [x] Resolves Phase 15 latent item: manifest `<service>` for `.BlePeripheralService` is now valid (class extends `Service`); `FOREGROUND_SERVICE_CONNECTED_DEVICE` perm in use. `.HealthServicesPlugin` entry still dead (not a Service) — out of scope.

### Phase 18 — LE Secure Connections bonding (iPhone in watch BT settings + reconnect) (2026-07-11)
- **Goal**: force an iOS-initiated LE Secure Connections bond so the iPhone appears in the watch system Bluetooth settings (the entry the user expected, matching Bridge) and reconnect-after-reboot works.
- **Mechanism (evidence-based, web-researched)**: mark ONE characteristic — `FE10 DeviceInfo`, the first char iOS reads after connect+subscribe — `PERMISSION_READ_ENCRYPTED`. The Bluedroid stack rejects an unbonded iOS central's FE10 read with `GATT_INSUFFICIENT_AUTHENTICATION` (0x05) BEFORE invoking `onCharacteristicReadRequest`, so CoreBluetooth auto-shows the system "Pair" dialog and retries the read after the LE Secure Connections bond completes. Apple-recommended pattern (dedicated encrypted trigger char).
- [x] `permsFor`: special-case `Uuids.deviceInfo` → `PERMISSION_READ_ENCRYPTED`. ALL other chars (health/call/music/notify + CCCD writes) stay UNENCRYPTED → graceful degradation: if the user dismisses the Pair dialog, only DeviceInfo (name) is lost; call/music/health still work. No `PERMISSION_*_ENCRYPTED_MITM` (would force a 6-digit passkey — avoided).
- [x] Device name in advertisement: `startAdvertising` switched to the 4-arg overload with the watch BT name in the SCAN RESPONSE (separate 31-byte payload, no overflow with the 128-bit service UUID in the primary packet). `nameDropped` flag + errorCode-1 (`ADVERTISE_FAILED_DATA_TOO_LARGE`) one-shot fallback: retry UUID-only if the name overflows. Reset in `stopAdvertising()` so a later shortened name re-tries.
- [x] Diagnostic `BroadcastReceiver` for `BluetoothDevice.ACTION_BOND_STATE_CHANGED` (logs `BOND_NONE→BONDING→BONDED` to logcat for no-Mac debugging). Registered in `onCreate` with `RECEIVER_NOT_EXPORTED` (API 34+), unregistered in `onDestroy` with a flag guard. Typed `getParcelableExtra` on API 33+. Does NOT call `createBond()` — research says that races with the encrypted-char trigger (double SMP exchange / never-completes bond).
- [x] Fixed wrong errorCode comment (AOSP-verified: `DATA_TOO_LARGE=1, TOO_MANY_ADVERTISERS=2, ALREADY_STARTED=3, INTERNAL_ERROR=4, FEATURE_UNSUPPORTED=5` — prior comment had 4/5 swapped).
- [x] No iOS-side change: CoreBluetooth handles pairing transparently (system dialog + encrypted read retry + notify-subscription restore after the transient re-encrypt disconnect). `BLEManager` reconnect-scan path handles the transient drop.
- [x] Verify: `flutter analyze` clean, `flutter build apk --debug` OK (173 MB APK). Adversarial review: SHIP — 2 LOW findings applied (deprecated `getParcelableExtra` guard; `nameDropped` reset).
- [ ] Verify on device: reinstall watch APK → iPhone connects → iOS shows "Pair" dialog → user accepts → watch logcat `bondStateChange … 11 -> 12` (BONDED) → iPhone now listed in watch system Bluetooth settings → reboot watch → iPhone auto-reconnects (bond stored).
- [ ] **iOS 17+ edge case (non-universal, dotnet-bluetooth-le #932)**: pairing popup may not appear on the first INSUFFICIENT_AUTHENTICATION; a disconnect+reconnect may be needed. The BLEManager reconnect path covers it if triggered. Cannot fix Android-side.
- [ ] **Optional iOS polish (future)**: surface a "Pairing required" prompt in `GattClient.didUpdateValueFor` FE10 error path (currently only `print`s). Not required for the bond to form.

### Phase 16 — On-device BLE diagnostics + discoverability (2026-07-11)
- **Symptom**: watch installs + advertises (logcat: `advertise onStartSuccess`), but iPhone never connects; user has no Mac to read os_log.
- **Architecture fact confirmed**: watch=peripheral (advertises only, never scans) → it will NEVER show the iPhone in the watch's system Bluetooth settings. "Bridge WearSync" shows it because that app runs the watch as CENTRAL (scans+connects to iPhone → bond → appears). Our app's connection is iPhone→watch; no system-pairing entry is expected unless bonding is added.
- [x] iOS in-app BLE log screen (`BLELogView.swift`): shows full state-machine trace (permission state → scan cycles → discovery → connect → GATT service/char discovery → health config) with no Mac needed. `BLEManager.logEntries` observable buffer mirrors os_log.
- [x] `BLEManager` + `GattClient` log every milestone via `log(_:)` / `onLog` (poweredOn/unauthorized, scan on/rest/backoff, discovered RSSI, connected, didDiscoverServices + char list, subscribed count, missing-char warnings, FE10 read, health config sent, disconnect/fail).
- [x] DevicesListView toolbar: BLE Logs button (icon color = conn state: green/orange/red/gray).
- [x] Watch advertiser bumped `ADVERTISE_MODE_LOW_POWER`+`TX_POWER_LOW` → `LOW_LATENCY`+`HIGH` while disconnected for reliable first-time iOS discovery (was marginal at 1s/low power vs iPhone's 2s scan window). `stopAdvertising()` on connect bounds battery cost.
- [ ] Verify on device: rebuild watch APK + reinstall; rebuild iOS IPA (CI) + reinstall; open BLE Logs on iPhone; confirm which step fails.
- [ ] **Open question**: if iPhone connects but user still expects the watch BT-settings entry, consider marking characteristics `PERMISSION_*_ENCRYPTED` to force iOS-initiated bonding (would list iPhone in watch BT settings). Not needed for function.

---

## Metrics Log
... (omitted for brevity)
